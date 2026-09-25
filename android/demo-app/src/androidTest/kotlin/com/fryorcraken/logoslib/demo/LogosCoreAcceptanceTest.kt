package com.fryorcraken.logoslib.demo

import android.os.Process
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.fryorcraken.logoslib.core.LogosCore
import com.fryorcraken.logoslib.core.LogosJson
import com.fryorcraken.logoslib.core.RuntimeState
import com.fryorcraken.logoslib.core.StartInfo
import com.fryorcraken.logoslib.core.SubscriptionStatus
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.MethodSorters
import java.io.File
import kotlin.time.Duration.Companion.seconds

/**
 * Plan milestone M4 acceptance, on the x86_64 API 34 emulator:
 * start ok and capability_module runs in a liblogos_host_qt.so child of this process;
 * knownModules has capability_module and hello_module; loadModule(hello_module) is true and
 * a second child hosts it; call(hello_module, ping) == "\"pong\""; an event arrives within
 * 5 s; stop() leaves no child behind.
 *
 * The runtime is per process, so the tests share one [LogosCore] and run in name order.
 * Timings are logged under tag [TAG] for the integration report.
 *
 * Run: ./gradlew :demo-app:connectedDebugAndroidTest (after build-jni.sh + stage.sh), or
 * scripts/android/run-m4.sh, which also collects logcat/ps evidence.
 */
@RunWith(AndroidJUnit4::class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class LogosCoreAcceptanceTest {

    companion object {
        private const val TAG = "LogosM4Test"
        private const val HELLO = "hello_module"
        private const val EVENT = "hello"

        private lateinit var core: LogosCore
        private lateinit var info: StartInfo

        @BeforeClass
        @JvmStatic
        fun startRuntime() {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            core = LogosCore(context)
            val t = SystemClock.elapsedRealtime()
            info = runBlocking { core.start() }
            Log.i(TAG, "TIMING start ${SystemClock.elapsedRealtime() - t} ms ($info)")
        }

        @AfterClass
        @JvmStatic
        fun stopRuntime() {
            if (!::core.isInitialized || !core.isRunning) return
            val t = SystemClock.elapsedRealtime()
            core.stop()
            val stopped = runBlocking { core.awaitStopped(20.seconds) }
            Log.i(TAG, "TIMING stop ${SystemClock.elapsedRealtime() - t} ms (stopped=$stopped)")
            assertTrue("runtime did not stop", stopped)
            assertEquals(RuntimeState.STOPPED, core.state.value)
            // logos_core_cleanup() terminates the module hosts; allow them a moment to be reaped.
            val deadline = SystemClock.elapsedRealtime() + 5_000
            var left = hostChildren()
            while (left.isNotEmpty() && SystemClock.elapsedRealtime() < deadline) {
                Thread.sleep(50)
                left = hostChildren()
            }
            Log.i(TAG, "module host children after stop: ${left.size} $left")
            assertTrue("module hosts still running after stop(): $left", left.isEmpty())
        }

        /**
         * The module host processes (liblogos_host_qt.so) that are children of this process,
         * as "pid: command line", read from /proc (same uid and SELinux domain, so visible).
         */
        fun hostChildren(): List<String> {
            val me = Process.myPid()
            val dirs = File("/proc").listFiles { f -> f.name.isNotEmpty() && f.name.all(Char::isDigit) }.orEmpty()
            return dirs.mapNotNull { d ->
                // /proc/<pid>/stat: "pid (comm) state ppid ..."; comm may contain spaces.
                val stat = runCatching { File(d, "stat").readText() }.getOrNull() ?: return@mapNotNull null
                val ppid = stat.substringAfterLast(')').trim().split(' ').getOrNull(1)?.toIntOrNull()
                if (ppid != me) return@mapNotNull null
                val argv = runCatching { File(d, "cmdline").readBytes().toString(Charsets.UTF_8) }.getOrNull()
                    ?.split('\u0000')?.filter { it.isNotEmpty() } ?: return@mapNotNull null
                if (argv.firstOrNull()?.endsWith("liblogos_host_qt.so") != true) return@mapNotNull null
                "${d.name}: ${argv.joinToString(" ")}"
            }.sorted()
        }

        private fun hostFor(children: List<String>, module: String): String? =
            children.firstOrNull { it.contains("--name $module ") || it.endsWith("--name $module") }
    }

    @Test
    fun t1_startIsOk() {
        assertTrue(core.isRunning)
        assertEquals(RuntimeState.RUNNING, core.state.value)
        Log.i(TAG, "qt=${info.qtVersion} protocol=${info.protocolVersion} qtCoreOnLoad=${info.qtCoreJniOnLoadResult}")
        // logos_core_start() brought capability_module up in its own module host process.
        val children = hostChildren()
        Log.i(TAG, "module host children after start (my pid ${Process.myPid()}): $children")
        assertTrue("no liblogos_host_qt.so child hosts capability_module: $children",
            hostFor(children, "capability_module") != null)
    }

    @Test
    fun t2_knownModules() {
        val known = core.knownModules()
        Log.i(TAG, "known modules: $known")
        assertTrue("capability_module not known: $known", "capability_module" in known)
        assertTrue("$HELLO not known: $known", HELLO in known)
    }

    @Test
    fun t3_loadHelloModule() = runBlocking<Unit> {
        val t = SystemClock.elapsedRealtime()
        val ok = core.loadModule(HELLO)
        Log.i(TAG, "TIMING load $HELLO ${SystemClock.elapsedRealtime() - t} ms -> $ok")
        assertTrue("loadModule($HELLO) returned false", ok)
        val loaded = core.loadedModules()
        assertTrue("$HELLO not in loaded modules $loaded", HELLO in loaded)
        // A second module host process now runs hello_module.
        val children = hostChildren()
        Log.i(TAG, "module host children after load: ${children.size} $children")
        assertTrue("no liblogos_host_qt.so child hosts $HELLO: $children", hostFor(children, HELLO) != null)
        assertTrue("capability_module's host is gone: $children", hostFor(children, "capability_module") != null)
    }

    @Test
    fun t4_pingReturnsPong() = runBlocking<Unit> {
        val t = SystemClock.elapsedRealtime()
        var attempts = 0
        val json = core.callWithRetry(HELLO, "ping", accept = { attempts++; it != "\"\"" && it != "null" })
        Log.i(TAG, "TIMING first ping ${SystemClock.elapsedRealtime() - t} ms, $attempts attempt(s) -> $json")
        assertEquals("\"pong\"", json)

        val t2 = SystemClock.elapsedRealtime()
        assertEquals("\"pong\"", core.call(HELLO, "ping"))
        Log.i(TAG, "TIMING warm ping ${SystemClock.elapsedRealtime() - t2} ms")
    }

    @Test
    fun t5_echoRoundTripsUnicode() = runBlocking<Unit> {
        val s = "héllo ✓ 😀 \"quoted\" \\ end"
        val json = core.call(HELLO, "echo", LogosJson.array(s))
        assertEquals(s, LogosJson.stringOrNull(json))
    }

    @Test
    fun t6_eventArrivesWithin5s() = runBlocking<Unit> {
        val sub = core.subscribe(HELLO, EVENT)
        try {
            val ta = SystemClock.elapsedRealtime()
            val status = sub.awaitArmed(10.seconds)
            Log.i(TAG, "TIMING armed ${SystemClock.elapsedRealtime() - ta} ms ($status)")
            assertEquals(SubscriptionStatus.State.ARMED, status.state)

            val tag = "m4-${System.nanoTime()}"
            val tf = SystemClock.elapsedRealtime()
            val fired = core.call(HELLO, "fire", LogosJson.array(tag))
            Log.i(TAG, "fire($tag) -> $fired")
            // Events are buffered in the subscription's channel, so collecting after the
            // call cannot miss one.
            val ev = withTimeout(5.seconds) { sub.events.first { it.argAsString(0) == tag } }
            Log.i(TAG, "TIMING event ${SystemClock.elapsedRealtime() - tf} ms after fire: ${ev.name} ${ev.dataJson}")
            assertEquals(EVENT, ev.name)
            assertEquals(HELLO, ev.module)
        } finally {
            sub.close()
        }
    }

    @Test
    fun t7_methodsListsPing() = runBlocking<Unit> {
        val json = core.methods(HELLO)
        Log.i(TAG, "getPluginMethods: $json")
        val names = (LogosJson.parse(json) as List<*>).mapNotNull { (it as? Map<*, *>)?.get("name") as? String }
        assertTrue("ping missing from $names", "ping" in names)
    }
}
