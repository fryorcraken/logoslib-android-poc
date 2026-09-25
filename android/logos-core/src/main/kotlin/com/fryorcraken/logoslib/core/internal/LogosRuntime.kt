package com.fryorcraken.logoslib.core.internal

import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.fryorcraken.logoslib.core.LogosCallException
import com.fryorcraken.logoslib.core.LogosConfig
import com.fryorcraken.logoslib.core.LogosCore
import com.fryorcraken.logoslib.core.LogosEvent
import com.fryorcraken.logoslib.core.LogosException
import com.fryorcraken.logoslib.core.LogosSubscription
import com.fryorcraken.logoslib.core.LogosTimeoutException
import com.fryorcraken.logoslib.core.RuntimeState
import com.fryorcraken.logoslib.core.StartInfo
import com.fryorcraken.logoslib.core.SubscriptionStatus
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * The one liblogos runtime of this process (Qt allows one QCoreApplication per process, and
 * liblogos keeps process-global state). Every [LogosCore] instance delegates here.
 *
 * Threading model (docs/plan.md "Host threading", desktop experiment X7):
 *  - a dedicated, JVM-attached `logos-qt` thread runs [LogosNative.nativeRun] (QCoreApplication,
 *    logos_core_start, exec) and nothing else; every lp_* callback arrives there and only
 *    hands off (CompletableDeferred.complete / Channel.trySend);
 *  - calls use lp_invoke_async with a Long call id; the Kotlin deadline is authoritative and
 *    a late result is dropped (natively via nativeCancelCall, and here if it still arrives);
 *  - blocking native entry points (load, first lp_client_create, subscribe) run detached on
 *    [scope] (Dispatchers.IO) so a caller's timeout/cancellation returns immediately even
 *    though the native call cannot be interrupted.
 */
internal object LogosRuntime : LogosNative.NativeSink {
    private const val TAG = "LogosCore"

    /** Qt event loops nest (QtRO waits, capability_module calls); give the thread room. */
    private const val QT_THREAD_STACK_BYTES = 8L * 1024 * 1024

    private val _state = MutableStateFlow(RuntimeState.NEW)
    val state: StateFlow<RuntimeState> = _state.asStateFlow()

    @Volatile
    var info: StartInfo? = null
        private set

    private val startMutex = Mutex()
    private var loopThread: Thread? = null

    @Volatile
    private var ready: CompletableDeferred<Unit>? = null
    private val stopped = CompletableDeferred<Int>()

    /** Owns detached blocking native calls; never cancelled. */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO + CoroutineName("logos-runtime"))

    private val nextId = AtomicLong(0)

    private class RawResult(val ok: Boolean, val json: String)
    private class Listener(val module: String, val event: String, val channel: Channel<LogosEvent>)

    private val pendingCalls = ConcurrentHashMap<Long, CompletableDeferred<RawResult>>()
    private val listeners = ConcurrentHashMap<Long, Listener>()
    private val statuses = ConcurrentHashMap<String, MutableStateFlow<SubscriptionStatus>>()
    private val moduleMutexes = ConcurrentHashMap<String, Mutex>()

    // ---------------------------------------------------------------- lifecycle

    suspend fun start(context: Context, config: LogosConfig, modules: List<String>): StartInfo =
        startMutex.withLock {
            info?.let { if (_state.value == RuntimeState.RUNNING) return it }
            check(_state.value == RuntimeState.NEW) {
                "liblogos runtime is ${_state.value}; it cannot be restarted in the same process " +
                    "(one QCoreApplication per process, liblogos keeps global state)"
            }
            _state.value = RuntimeState.STARTING
            try {
                val started = withContext(Dispatchers.IO) { doStart(context.applicationContext, config, modules) }
                info = started
                _state.value = RuntimeState.RUNNING
                started
            } catch (t: Throwable) {
                // Before the loop thread exists nothing native is running: allow another try.
                _state.value = if (loopThread == null) RuntimeState.NEW else RuntimeState.FAILED
                throw t
            }
        }

    private suspend fun doStart(ctx: Context, config: LogosConfig, modules: List<String>): StartInfo {
        val t0 = SystemClock.elapsedRealtime()
        val layout = Layout.from(ctx)
        SocketPathBudget.require(layout.tmpDir.path, listOf("capability_module"))

        val env = RuntimeEnv.apply(layout)
        layout.persistDir.mkdirs()
        val assets = ModuleAssets.extract(ctx, layout.abi, layout.modulesDir, modules, config.readOnlyModules)
        SocketPathBudget.require(layout.tmpDir.path, assets.modules)

        NativeLibs.load(layout)
        if (config.redirectStdioToLogcat) LogosNative.nativeRedirectStdio("logos-stdio")
        val primeRc = LogosNative.nativeQtCorePrimeResult()
        Log.i(
            TAG,
            "starting liblogos: abi=${layout.abi} protocol=${LogosNative.nativeProtocolVersion()} " +
                "qt=${LogosNative.nativeQtVersion()} QtCore JNI_OnLoad(realVM)=$primeRc env=$env",
        )

        LogosNative.sink = this
        val readyDeferred = CompletableDeferred<Unit>()
        ready = readyDeferred
        val thread = Thread(null, { runLoop(layout, config) }, "logos-qt", QT_THREAD_STACK_BYTES)
        loopThread = thread
        thread.start()
        withTimeoutOrNull(config.startTimeout) { readyDeferred.await() }
            ?: throw LogosTimeoutException("liblogos did not come up within ${config.startTimeout}")
        val tookMs = SystemClock.elapsedRealtime() - t0
        Log.i(TAG, "liblogos running after $tookMs ms; known modules: ${knownModules()}")
        return StartInfo(
            abi = layout.abi,
            nativeLibraryDir = layout.nativeLibDir.path,
            tmpDir = layout.tmpDir.path,
            modulesDir = layout.modulesDir.path,
            persistDir = layout.persistDir.path,
            packagedModules = assets.modules,
            modulesExtracted = assets.extracted,
            environment = env,
            qtVersion = LogosNative.nativeQtVersion(),
            protocolVersion = LogosNative.nativeProtocolVersion(),
            qtCoreJniOnLoadResult = primeRc,
            startMillis = tookMs,
        )
    }

    private fun runLoop(layout: Layout, config: LogosConfig) {
        var rc = Int.MIN_VALUE
        try {
            rc = LogosNative.nativeRun(layout.modulesDir.path, layout.persistDir.path, "logos-android", config.originModule)
            Log.i(TAG, "Qt loop exited with $rc")
        } catch (t: Throwable) {
            Log.e(TAG, "nativeRun threw", t)
        } finally {
            onLoopExit(rc)
        }
    }

    private fun onLoopExit(rc: Int) {
        val wasUp = _state.value == RuntimeState.RUNNING || _state.value == RuntimeState.STOPPING
        _state.value = if (wasUp) RuntimeState.STOPPED else RuntimeState.FAILED
        ready?.completeExceptionally(LogosException("Qt loop exited (rc=$rc) before it was ready"))
        val stoppedEx = LogosException("liblogos runtime stopped")
        pendingCalls.keys.toList().forEach { id -> pendingCalls.remove(id)?.completeExceptionally(stoppedEx) }
        listeners.keys.toList().forEach { id -> listeners.remove(id)?.channel?.close() }
        stopped.complete(rc)
    }

    fun stop(): Boolean {
        if (_state.value != RuntimeState.RUNNING) return false
        _state.value = RuntimeState.STOPPING
        val posted = LogosNative.nativeStop()
        if (!posted) Log.w(TAG, "stop: no Qt loop to quit")
        return posted
    }

    suspend fun awaitStopped(): Int = stopped.await()

    fun requireRunning() {
        val s = _state.value
        if (s != RuntimeState.RUNNING) throw IllegalStateException("liblogos runtime is $s (call start() first)")
    }

    // ---------------------------------------------------------------- native callbacks

    override fun ready() {
        ready?.complete(Unit)
    }

    override fun invokeResult(callId: Long, ok: Boolean, json: String) {
        val d = pendingCalls.remove(callId)
        if (d == null) {
            Log.d(TAG, "late result for call $callId dropped")
            return
        }
        d.complete(RawResult(ok, json))
    }

    override fun event(listenerId: Long, event: String, dataJson: String) {
        val l = listeners[listenerId] ?: return
        l.channel.trySend(LogosEvent(l.module, event, dataJson))
    }

    override fun subscriptionStatus(module: String, state: Int, generation: Long, reason: String?) {
        statusFlow(module).value = SubscriptionStatus(SubscriptionStatus.State.fromNative(state), generation, reason)
        Log.i(TAG, "subscription status $module: state=$state generation=$generation reason=$reason")
    }

    // ---------------------------------------------------------------- operations

    /** Runs a blocking native call on [scope]; the caller may give up without waiting for it. */
    suspend fun <T> detached(block: () -> T): T = scope.async { block() }.await()

    fun mutexFor(module: String): Mutex = moduleMutexes.getOrPut(module) { Mutex() }

    fun statusFlow(module: String): MutableStateFlow<SubscriptionStatus> =
        statuses.getOrPut(module) { MutableStateFlow(SubscriptionStatus(SubscriptionStatus.State.NONE)) }

    fun knownModules(): List<String> = LogosNative.nativeKnownModules().toList()

    fun loadedModules(): List<String> = LogosNative.nativeLoadedModules().toList()

    fun tmpDir(): String = info?.tmpDir ?: ""

    /**
     * lp_invoke_async(module, method, argsJson) and wait for its callback. No timeout here:
     * the caller wraps this in withTimeout; whatever way this returns, the call id is
     * forgotten so a late callback is dropped.
     */
    suspend fun invoke(module: String, method: String, argsJson: String, lpTimeoutMs: Int): String {
        requireRunning()
        val id = nextId.incrementAndGet()
        val result = CompletableDeferred<RawResult>()
        pendingCalls[id] = result
        try {
            val rc = detached { LogosNative.nativeInvokeAsync(module, method, argsJson, lpTimeoutMs, id) }
            if (rc != 0) throw LogosException("lp_invoke_async($module.$method) was not dispatched: ${dispatchError(rc)}")
            val r = result.await()
            if (r.ok) return r.json
            throw LogosCallException.fromErrorJson(module, method, r.json)
        } finally {
            if (pendingCalls.remove(id) != null) runCatching { LogosNative.nativeCancelCall(id) }
        }
    }

    suspend fun subscribe(core: LogosCore, module: String, event: String, capacity: Int): LogosSubscription {
        requireRunning()
        val id = nextId.incrementAndGet()
        val channel = Channel<LogosEvent>(capacity, BufferOverflow.DROP_OLDEST)
        val sub = LogosSubscription(module, event, id, channel, core) { closeSubscription(it.listenerId) }
        statusFlow(module)
        // Register before subscribing: an event may arrive before lp_subscribe returns.
        listeners[id] = Listener(module, event, channel)
        val job = scope.async { LogosNative.nativeSubscribe(module, event, id) }
        val rc = try {
            job.await()
        } catch (e: CancellationException) {
            listeners.remove(id)
            channel.close()
            // The native subscribe may still complete; undo it when it does.
            scope.launch { if (runCatching { job.await() }.getOrNull() == 0) LogosNative.nativeUnsubscribe(id) }
            throw e
        }
        if (rc != 0) {
            listeners.remove(id)
            channel.close()
            throw LogosException("lp_subscribe($module, $event) failed: ${dispatchError(rc)}")
        }
        return sub
    }

    fun closeSubscription(listenerId: Long) {
        val l = listeners.remove(listenerId) ?: return
        if (_state.value == RuntimeState.RUNNING) {
            runCatching { LogosNative.nativeUnsubscribe(listenerId) }
                .onFailure { Log.w(TAG, "unsubscribe($listenerId) failed", it) }
        }
        l.channel.close()
    }

    private fun dispatchError(rc: Int): String = when (rc) {
        -1 -> "LP_ERR_INVALID_ARG"
        -2 -> "LP_ERR_UNSUPPORTED"
        -3 -> "LP_ERR_INTERNAL"
        -4 -> "LP_ERR_UNAVAILABLE"
        LogosNative.ERR_NOT_RUNNING -> "runtime not running"
        LogosNative.ERR_NO_CLIENT -> "lp_client_create failed"
        else -> "rc=$rc"
    }
}
