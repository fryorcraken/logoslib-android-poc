package com.fryorcraken.logoslib.core

import android.content.Context
import com.fryorcraken.logoslib.core.internal.LogosNative
import com.fryorcraken.logoslib.core.internal.LogosRuntime
import com.fryorcraken.logoslib.core.internal.SocketPathBudget
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** Lifecycle of the process-wide liblogos runtime. */
public enum class RuntimeState { NEW, STARTING, RUNNING, STOPPING, STOPPED, FAILED }

/** What [LogosCore.start] set up, for logs and diagnostics. */
public data class StartInfo(
    val abi: String,
    val nativeLibraryDir: String,
    val tmpDir: String,
    val modulesDir: String,
    val persistDir: String,
    /** Module directories extracted from assets (what liblogos can discover). */
    val packagedModules: List<String>,
    /** False when the extracted tree was already current. */
    val modulesExtracted: Boolean,
    /** Variables set with Os.setenv before loading the runtime. */
    val environment: Map<String, String>,
    val qtVersion: String,
    val protocolVersion: String,
    /** QtCore's JNI_OnLoad(realVM) as called by liblogos_jni; -1 (JNI_ERR) is expected without Qt6Android.jar. */
    val qtCoreJniOnLoadResult: Int,
    val startMillis: Long,
)

/**
 * Kotlin API for liblogos (logos-liblogos `db45024`) embedded in an Android app.
 *
 * liblogos_core and liblogos_protocol run inside the app process; every module runs in its
 * own child process (`liblogos_host_qt.so`, exec'd from nativeLibraryDir) and is reached over
 * QtRO unix sockets in the app's cacheDir. This class wraps the two C ABIs:
 *  - `logos_core_*` (logos_core.h): start, discover and load modules;
 *  - `lp_*` (logos_protocol.h): call module methods and subscribe to module events, both
 *    JSON-in-strings.
 *
 * All instances in a process share one runtime ([RuntimeState]): Qt allows one
 * QCoreApplication per process, and a stopped runtime cannot be restarted in the same process.
 *
 * Typical use (from a coroutine; nothing here blocks the calling thread):
 * ```
 * val core = LogosCore(context)
 * core.start()
 * core.loadModule("hello_module")
 * val pong = core.callWithRetry("hello_module", "ping")          // "\"pong\""
 * core.events("hello_module", "hello").collect { println(it.args) }
 * ```
 *
 * @param config timeouts and switches, see [LogosConfig].
 */
public class LogosCore(context: Context, public val config: LogosConfig = LogosConfig()) {

    private val appContext: Context = context.applicationContext
    private val runtime = LogosRuntime

    /** State of the process-wide runtime. */
    public val state: StateFlow<RuntimeState> get() = runtime.state

    public val isRunning: Boolean get() = runtime.state.value == RuntimeState.RUNNING

    /** Set once [start] succeeded. */
    public val startInfo: StartInfo? get() = runtime.info

    /**
     * Starts liblogos in this process; idempotent once running.
     *
     * In order: sets TMPDIR (= cacheDir, checked against the 108-byte `sun_path` budget),
     * HOME, LD_LIBRARY_PATH and LOGOS_HOST_PATH with `Os.setenv`; extracts the packaged
     * module directories to `filesDir/modules` (re-extracting when the APK or the staged
     * modules changed); loads the native libraries; then starts the dedicated `logos-qt`
     * thread, which creates the QCoreApplication, calls `logos_core_init`,
     * `logos_core_add_modules_dir`, `logos_core_set_persistence_base_path(filesDir/persist)`
     * and `logos_core_start` (which brings up capability_module in a child process), and runs
     * the Qt event loop. Returns once that loop is running.
     *
     * @param modules module directories to extract; empty means every packaged module.
     * @throws LogosTimeoutException if the loop is not up within [LogosConfig.startTimeout].
     * @throws IllegalStateException if the runtime already stopped or failed in this process,
     *   or the native runtime was not staged into the APK.
     */
    public suspend fun start(modules: List<String> = emptyList()): StartInfo =
        runtime.start(appContext, config, modules)

    /** Module names liblogos discovered in the modules directory (`logos_core_get_known_modules`). */
    public fun knownModules(): List<String> {
        runtime.requireRunning()
        return runtime.knownModules()
    }

    /** Currently loaded module names (`logos_core_get_loaded_modules`). */
    public fun loadedModules(): List<String> {
        runtime.requireRunning()
        return runtime.loadedModules()
    }

    /** `logos_core_get_modules_info()`: a JSON array describing every known module. */
    public fun modulesInfoJson(): String {
        runtime.requireRunning()
        return LogosNative.nativeModulesInfo() ?: "[]"
    }

    /**
     * Loads [name] (and, per [deps], its dependencies), each into its own host process.
     * "Ensure loaded" semantics: true also when it was already loaded.
     *
     * Runs off the Qt thread on purpose: a load on the Qt thread would wedge every other
     * caller for the whole host bring-up. Consequence (logos_core.h): the capability
     * registration completes asynchronously after this returns -- use [callWithRetry] for
     * the first call.
     *
     * @throws LogosTimeoutException after [timeout]; the native load keeps going.
     */
    public suspend fun loadModule(
        name: String,
        deps: LoadDeps = LoadDeps.REQUIRED,
        timeout: Duration = config.loadTimeout,
    ): Boolean {
        runtime.requireRunning()
        SocketPathBudget.require(runtime.tmpDir(), listOf(name))
        return deadline(timeout, "loadModule($name)") {
            runtime.detached { LogosNative.nativeLoadModule(name, deps.native) == 1 }
        }
    }

    /** Unloads [name] (and, if [withDependents], everything depending on it first). */
    public suspend fun unloadModule(
        name: String,
        withDependents: Boolean = false,
        timeout: Duration = config.loadTimeout,
    ): Boolean {
        runtime.requireRunning()
        return deadline(timeout, "unloadModule($name)") {
            runtime.detached { LogosNative.nativeUnloadModule(name, withDependents) == 1 }
        }
    }

    /**
     * Calls [method] on [module] and returns its result as a JSON value (e.g. `"\"pong\""`).
     *
     * Goes through `lp_invoke_async`, so neither the caller nor the Qt thread blocks. At most
     * one call per module is in flight (a Kotlin Mutex): modules serve one call at a time
     * anyway, and a timed-out call keeps its module busy. [timeout] covers the wait for that
     * slot plus the call itself.
     *
     * @param argsJson a JSON array of arguments; build it with [LogosJson.array].
     * @throws LogosCallException with liblogos' error code (e.g. `object_unavailable`).
     * @throws LogosTimeoutException after [timeout]; a late result is dropped.
     */
    public suspend fun call(
        module: String,
        method: String,
        argsJson: String = "[]",
        timeout: Duration = config.callTimeout,
    ): String {
        runtime.requireRunning()
        require(argsJson.trimStart().startsWith("[")) { "argsJson must be a JSON array, got: $argsJson" }
        val lpTimeoutMs = (timeout + config.lpTimeoutMargin).inWholeMilliseconds
            .coerceIn(1L, Int.MAX_VALUE.toLong()).toInt()
        return deadline(timeout, "$module.$method") {
            runtime.mutexFor(module).withLock { runtime.invoke(module, method, argsJson, lpTimeoutMs) }
        }
    }

    /**
     * [call], repeated until [accept] likes the answer: the first-call-after-load helper
     * (see [FirstCallRetry]). Only for idempotent methods. Retries every
     * [LogosConfig.firstCallRetryBackoff] for up to [budget]; then returns the last answer.
     */
    public suspend fun callWithRetry(
        module: String,
        method: String,
        argsJson: String = "[]",
        timeout: Duration = config.callTimeout,
        budget: Duration = config.firstCallRetryBudget,
        accept: (String) -> Boolean = FirstCallRetry::isNonDefault,
    ): String = FirstCallRetry.retryUntil(budget, config.firstCallRetryBackoff, accept) {
        call(module, method, argsJson, timeout)
    }

    /**
     * The module's methods with signatures, as JSON (`getPluginMethods`, answered by the
     * module host without a token). `lp_get_methods` is not used: it returns `[]` for the QtRO
     * transport (remote introspection is unimplemented upstream).
     */
    public suspend fun methods(module: String, timeout: Duration = config.callTimeout): String =
        call(module, "getPluginMethods", "[]", timeout)

    /** The module's events, as JSON (`getPluginEvents`). */
    public suspend fun pluginEvents(module: String, timeout: Duration = config.callTimeout): String =
        call(module, "getPluginEvents", "[]", timeout)

    /**
     * Subscribes to [event] of [module] (`lp_subscribe`) and returns once the subscription is
     * registered; wait for delivery to be live with [LogosSubscription.awaitArmed]. Subscribe
     * after [loadModule]. An unknown event name is accepted and simply never fires.
     *
     * @param capacity events buffered for a slow collector; the oldest are dropped beyond it.
     */
    public suspend fun subscribe(module: String, event: String, capacity: Int = 64): LogosSubscription =
        runtime.subscribe(this, module, event, capacity)

    /** Cold flow of [event]s from [module]: subscribes on collection, unsubscribes on cancel. */
    public fun events(module: String, event: String): Flow<LogosEvent> = flow {
        val sub = subscribe(module, event)
        try {
            emitAll(sub.events)
        } finally {
            sub.close()
        }
    }

    /** Per-module subscription state (ARMED / LOST / HELD / ABANDONED with a generation). */
    public fun subscriptionStatus(module: String): StateFlow<SubscriptionStatus> =
        runtime.statusFlow(module).asStateFlow()

    /**
     * Suspends until [module]'s subscriptions are armed. logos-protocol polls pending
     * subscriptions on a 250 ms .. 5 s backoff, so an event fired before this returns can be
     * missed.
     */
    public suspend fun awaitArmed(module: String, timeout: Duration = config.armTimeout): SubscriptionStatus =
        withTimeoutOrNull(timeout) {
            runtime.statusFlow(module).first { it.state == SubscriptionStatus.State.ARMED }
        } ?: throw LogosTimeoutException(
            "$module subscriptions not armed within $timeout (pending: ${pendingSubscriptions(module)})",
        )

    /** `lp_pending_subscriptions` for [module]: subscriptions accepted but not armed yet. */
    public fun pendingSubscriptions(module: String): String? =
        if (isRunning) LogosNative.nativePendingSubscriptions(module) else null

    /**
     * Stops the runtime: posts a quit to the Qt loop, which then unsubscribes everything,
     * destroys the lp clients and calls `logos_core_cleanup()` (terminating the module
     * hosts). Returns immediately; see [awaitStopped]. The runtime cannot be started again
     * in this process.
     */
    public fun stop(): Boolean = runtime.stop()

    /** Waits for the Qt loop to finish after [stop]; false on timeout. */
    public suspend fun awaitStopped(timeout: Duration = 15.seconds): Boolean =
        withTimeoutOrNull(timeout) { runtime.awaitStopped() } != null

    /**
     * Runs [block] under [timeout] and reports OUR timeout as [LogosTimeoutException].
     * withTimeoutOrNull (not catching TimeoutCancellationException) so that a caller's own
     * enclosing withTimeout still surfaces as the cancellation it is.
     */
    private suspend fun <T> deadline(timeout: Duration, what: String, block: suspend () -> T): T {
        var done = false
        val result = withTimeoutOrNull(timeout) { block().also { done = true } }
        if (!done) throw LogosTimeoutException("$what did not finish within $timeout")
        @Suppress("UNCHECKED_CAST")
        return result as T
    }
}
