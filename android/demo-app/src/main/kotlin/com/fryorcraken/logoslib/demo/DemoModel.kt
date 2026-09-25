package com.fryorcraken.logoslib.demo

import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.fryorcraken.logoslib.core.LogosCore
import com.fryorcraken.logoslib.core.LogosJson
import com.fryorcraken.logoslib.core.LogosSubscription
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicInteger

/**
 * Process-wide demo state. The liblogos runtime is per process, so the demo's state lives
 * here rather than in the Activity: it survives Activity recreation like the runtime does.
 */
object DemoModel {
    const val HELLO = "hello_module"
    const val HELLO_EVENT = "hello"
    private const val TAG = "LogosDemo"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val t0 = SystemClock.elapsedRealtime()
    private val fireCount = AtomicInteger(0)

    @Volatile
    private var core: LogosCore? = null
    private var subscription: LogosSubscription? = null

    private val _log = MutableStateFlow<List<String>>(emptyList())
    val log: StateFlow<List<String>> = _log.asStateFlow()
    val known = MutableStateFlow<List<String>>(emptyList())
    val loaded = MutableStateFlow<List<String>>(emptyList())
    val lastPing = MutableStateFlow("-")
    val lastEvent = MutableStateFlow("-")
    val busy = MutableStateFlow(false)

    fun core(context: Context): LogosCore =
        core ?: synchronized(this) { core ?: LogosCore(context.applicationContext).also { core = it } }

    fun log(msg: String) {
        val line = "%6d ms  %s".format(SystemClock.elapsedRealtime() - t0, msg)
        Log.i(TAG, msg)
        _log.update { (it + line).takeLast(500) }
    }

    private fun op(name: String, block: suspend () -> Unit) {
        if (busy.value) {
            log("$name: busy, ignored")
            return
        }
        busy.value = true
        scope.launch {
            val t = SystemClock.elapsedRealtime()
            try {
                block()
            } catch (e: Exception) {
                log("$name FAILED: ${e.javaClass.simpleName}: ${e.message}")
                Log.e(TAG, "$name failed", e)
            } finally {
                log("$name took ${SystemClock.elapsedRealtime() - t} ms")
                busy.value = false
            }
        }
    }

    private fun refresh(c: LogosCore) {
        known.value = c.knownModules()
        loaded.value = c.loadedModules()
    }

    fun start(context: Context) = op("start") { doStart(context) }

    fun loadHello(context: Context) = op("load $HELLO") { doLoadHello(context) }

    fun ping(context: Context) = op("ping") { doPing(context) }

    fun fire(context: Context) = op("fire") { doFire(context) }

    /**
     * start -> load hello_module -> ping -> fire, for unattended runs:
     * `adb shell am start -n com.fryorcraken.logoslib.demo/.MainActivity --ez autorun true`.
     * Progress is logged under tag LogosDemo; "AUTORUN OK" / "AUTORUN FAILED" ends it.
     */
    fun autorun(context: Context) = op("autorun") {
        try {
            val c = core(context)
            if (!c.isRunning) doStart(context)
            if (HELLO !in c.loadedModules()) doLoadHello(context)
            doPing(context)
            val tag = doFire(context)
            val deadline = SystemClock.elapsedRealtime() + 5_000
            while (lastEvent.value != tag && SystemClock.elapsedRealtime() < deadline) delay(50)
            log(
                if (lastEvent.value == tag) "AUTORUN OK (ping=${lastPing.value}, event=${lastEvent.value})"
                else "AUTORUN FAILED: event $tag not received within 5 s",
            )
        } catch (e: Exception) {
            log("AUTORUN FAILED: ${e.javaClass.simpleName}: ${e.message}")
            throw e
        }
    }

    private suspend fun doStart(context: Context) {
        val c = core(context)
        val info = c.start()
        log("started: abi=${info.abi} qt=${info.qtVersion} protocol=${info.protocolVersion} in ${info.startMillis} ms")
        log("modules dir ${info.modulesDir} (extracted now: ${info.modulesExtracted}); TMPDIR ${info.tmpDir}")
        refresh(c)
        log("known modules: ${known.value}")
    }

    private suspend fun doLoadHello(context: Context) {
        val c = core(context)
        val ok = c.loadModule(HELLO)
        log("loadModule($HELLO) -> $ok")
        refresh(c)
        log("loaded modules: ${loaded.value}")
        if (ok && subscription == null) {
            val sub = c.subscribe(HELLO, HELLO_EVENT)
            subscription = sub
            scope.launch {
                sub.events.collect { ev ->
                    val tag = ev.argAsString(0) ?: ev.dataJson
                    lastEvent.value = tag
                    log("event ${ev.module}.${ev.name} ${ev.dataJson}")
                }
            }
            val st = sub.awaitArmed()
            log("subscribed to $HELLO.$HELLO_EVENT: ${st.state} (generation ${st.generation})")
        }
    }

    private suspend fun doPing(context: Context) {
        val c = core(context)
        // First call after a load: retry while the answer is the wrapper default ("").
        val json = c.callWithRetry(HELLO, "ping")
        lastPing.value = LogosJson.stringOrNull(json) ?: json
        log("ping -> $json")
    }

    private suspend fun doFire(context: Context): String {
        val c = core(context)
        val tag = "tag-${fireCount.incrementAndGet()}"
        val json = c.call(HELLO, "fire", LogosJson.array(tag))
        log("fire($tag) -> $json")
        return tag
    }

    fun methods(context: Context) = op("methods") {
        val json = core(context).methods(HELLO)
        log("$HELLO methods: ${json.take(600)}")
    }

    fun stop(context: Context) = op("stop") {
        val c = core(context)
        subscription?.close()
        subscription = null
        c.stop()
        val done = c.awaitStopped()
        log("stopped: $done (restart the app to start again)")
        loaded.value = emptyList()
    }
}
