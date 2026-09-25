package com.fryorcraken.logoslib.demo

import android.os.Process
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.fryorcraken.logoslib.core.LogosConfig
import com.fryorcraken.logoslib.core.LogosCore
import com.fryorcraken.logoslib.core.LogosModuleDiedException
import com.fryorcraken.logoslib.core.LogosSubscription
import com.fryorcraken.logoslib.core.ModuleExit
import com.fryorcraken.logoslib.core.RuntimeState
import com.fryorcraken.logoslib.core.SubscriptionStatus
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.MethodSorters
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/**
 * Plan milestones M5/M6 acceptance on the x86_64 API 34 emulator: the Logos blockchain node
 * (blockchain_module) runs in a liblogos_host_qt.so child of this app, joins devnet 0.3.0-rc.4
 * in follower mode, syncs to the tip, delivers newBlock events to Kotlin, answers bc_probe's
 * inter-module call, stops cleanly, and a killed host is reported instead of hanging calls.
 *
 * Needs the network and several minutes, so it runs only when asked:
 * `am instrument -w -e blockchain 1 -e class com.fryorcraken.logoslib.demo.BlockchainAcceptanceTest
 *  com.fryorcraken.logoslib.demo.test/androidx.test.runner.AndroidJUnitRunner`
 * (scripts/android/run-m5.sh does this). The liblogos runtime is per process and cannot be
 * restarted, so the class must have the instrumentation process to itself: when another class
 * already stopped the runtime, it is skipped. The node uses its own directory
 * (filesDir/blockchain-test, wiped first), so every run syncs from genesis.
 */
@RunWith(AndroidJUnit4::class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class BlockchainAcceptanceTest {

    companion object {
        private const val TAG = "LogosM5Test"
        private const val SYNC_TIMEOUT_MIN = 20L

        private lateinit var core: LogosCore
        private lateinit var node: BlockchainNode
        private var sub: LogosSubscription? = null
        private val blocks = AtomicInteger(0)
        private val firstBlock = CompletableDeferred<String>()
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        private var startCalledAt = 0L

        @BeforeClass
        @JvmStatic
        fun startRuntime() {
            val args = InstrumentationRegistry.getArguments()
            assumeTrue(
                "BlockchainAcceptanceTest needs the network and minutes: pass -e blockchain 1 (scripts/android/run-m5.sh)",
                args.getString("blockchain") == "1",
            )
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            core = LogosCore(context, LogosConfig(callTimeout = 30.seconds))
            assumeTrue(
                "the liblogos runtime already ran in this process (${core.state.value}); run this class in its own instrumentation",
                core.state.value == RuntimeState.NEW,
            )
            val t = SystemClock.elapsedRealtime()
            val info = runBlocking { core.start() }
            Log.i(TAG, "TIMING runtime start ${SystemClock.elapsedRealtime() - t} ms (extracted=${info.modulesExtracted}, cwd=${info.workDir})")
            node = BlockchainNode(core, context, nodeDirName = "blockchain-test")
        }

        @AfterClass
        @JvmStatic
        fun stopRuntime() {
            scope.cancel()
            if (!::core.isInitialized || !core.isRunning) return
            sub?.close()
            val t = SystemClock.elapsedRealtime()
            core.stop()
            val stopped = runBlocking { core.awaitStopped(30.seconds) }
            Log.i(TAG, "TIMING runtime stop ${SystemClock.elapsedRealtime() - t} ms (stopped=$stopped)")
            val deadline = SystemClock.elapsedRealtime() + 10_000
            var left = LogosCoreAcceptanceTest.hostChildren()
            while (left.isNotEmpty() && SystemClock.elapsedRealtime() < deadline) {
                Thread.sleep(100)
                left = LogosCoreAcceptanceTest.hostChildren()
            }
            Log.i(TAG, "module host children after stop: ${left.size} $left")
            assertTrue("runtime did not stop", stopped)
            assertTrue("module hosts still running after stop(): $left", left.isEmpty())
        }

        private fun hostFor(children: List<String>, module: String): String? =
            children.firstOrNull { it.contains("--name $module ") || it.endsWith("--name $module") }
    }

    @Test
    fun t01_knownModulesAndWorkingDir() {
        val known = core.knownModules()
        Log.i(TAG, "known modules: $known; cwd ${core.startInfo?.workDir}")
        assertTrue("blockchain_module not known: $known", BlockchainNode.MODULE in known)
        assertTrue("bc_probe not known: $known", BlockchainNode.PROBE in known)
        val files = InstrumentationRegistry.getInstrumentation().targetContext.filesDir
        assertEquals(File(files, "work").canonicalPath, File(core.startInfo!!.workDir).canonicalPath)
    }

    @Test
    fun t02_loadInOwnHosts() = runBlocking<Unit> {
        val t = SystemClock.elapsedRealtime()
        assertTrue("loadModule(blockchain_module, bc_probe) failed", node.load())
        Log.i(TAG, "TIMING load blockchain_module + bc_probe ${SystemClock.elapsedRealtime() - t} ms")
        val children = LogosCoreAcceptanceTest.hostChildren()
        Log.i(TAG, "module host children after load: ${children.size} $children")
        val bc = hostFor(children, BlockchainNode.MODULE)
        val probe = hostFor(children, BlockchainNode.PROBE)
        assertNotNull("no liblogos_host_qt.so child hosts blockchain_module: $children", bc)
        assertNotNull("no liblogos_host_qt.so child hosts bc_probe: $children", probe)
        assertNotNull("capability_module's host is gone: $children", hostFor(children, "capability_module"))
        assertTrue("blockchain_module and bc_probe share a process", bc!!.substringBefore(':') != probe!!.substringBefore(':'))
        // The host inherits the app's working directory (rapidsnark writes MyLogFile.log there).
        val pid = bc.substringBefore(':')
        val cwd = runCatching { File("/proc/$pid/cwd").canonicalPath }.getOrNull()
        Log.i(TAG, "blockchain_module host pid $pid cwd $cwd; stats ${core.moduleStats()}")
        if (cwd != null) assertEquals(File(core.startInfo!!.workDir).canonicalPath, cwd)
    }

    @Test
    fun t03_generateFollowerConfig() = runBlocking<Unit> {
        val notes = node.prepareConfig(fresh = true)
        Log.i(TAG, "config: $notes")
        val text = node.configFile.readText()
        assertTrue("follower mode not merged: ${node.configSummary()}", "31536000" in text)
        assertTrue("HTTP API not pinned to ${BlockchainNode.HTTP_ADDR}", BlockchainNode.HTTP_ADDR in text)
        assertTrue("keystore missing", node.keystoreFile.exists())
    }

    @Test
    fun t04_startNode() = runBlocking<Unit> {
        val s = node.subscribeNewBlocks()
        sub = s
        scope.launch {
            s.events.collect { ev ->
                if (node.parseNewBlock(ev.dataJson) != null && blocks.incrementAndGet() == 1) firstBlock.complete(ev.dataJson)
            }
        }
        val armed = s.awaitArmed(15.seconds)
        assertEquals(SubscriptionStatus.State.ARMED, armed.state)
        startCalledAt = SystemClock.elapsedRealtime()
        val ms = node.start()
        Log.i(TAG, "TIMING start() ${ms} ms")
        val info = node.cryptarchiaInfo()
        Log.i(TAG, "after start: $info chain=${node.chainId()} time=${node.timeInfo()}")
        assertEquals("Bootstrapping", info.mode)
    }

    @Test
    fun t05_peers() = runBlocking<Unit> {
        var net: BlockchainNode.NetworkInfo? = null
        withTimeout(3.minutes) {
            while (true) {
                val n = node.networkInfo()
                if (n.nPeers > 0) {
                    net = n
                    break
                }
                delay(1_000)
            }
        }
        Log.i(TAG, "TIMING first peer ${SystemClock.elapsedRealtime() - startCalledAt} ms after start(): $net")
        assertTrue((net?.nPeers ?: 0) > 0)
    }

    @Test
    fun t06_syncsToTip() = runBlocking<Unit> {
        val t0 = SystemClock.elapsedRealtime()
        var lastLog = 0L
        var last: BlockchainNode.ChainInfo? = null
        var lag = Long.MAX_VALUE
        while (SystemClock.elapsedRealtime() - t0 < SYNC_TIMEOUT_MIN * 60_000) {
            val c = node.cryptarchiaInfo()
            val now = node.timeInfo().currentSlot
            last = c
            lag = now - c.slot
            if (c.height > 0 && lag <= BlockchainModel.SYNC_LAG_SLOTS) break
            if (SystemClock.elapsedRealtime() - lastLog > 15_000) {
                lastLog = SystemClock.elapsedRealtime()
                Log.i(TAG, "syncing: height ${c.height} slot ${c.slot} current $now lag $lag peers ${node.networkInfo().nPeers} blocks ${blocks.get()} stats ${core.moduleStats().firstOrNull { it.name == BlockchainNode.MODULE }}")
            }
            delay(2_000)
        }
        Log.i(TAG, "TIMING synced ${SystemClock.elapsedRealtime() - startCalledAt} ms after start(): $last lag $lag slots, newBlock events ${blocks.get()}")
        assertTrue("not at the tip after $SYNC_TIMEOUT_MIN min: $last lag $lag", (last?.height ?: 0) > 0 && lag <= BlockchainModel.SYNC_LAG_SLOTS)
    }

    @Test
    fun t07_newBlockEventsReachKotlin() = runBlocking<Unit> {
        val payload = withTimeout(2.minutes) { firstBlock.await() }
        Log.i(TAG, "newBlock events: ${blocks.get()}; first payload ${payload.take(300)}")
        assertTrue(blocks.get() > 0)
    }

    @Test
    fun t08_bcProbeCallsBlockchainModule() = runBlocking<Unit> {
        val direct = node.cryptarchiaInfo()
        val p = node.chainInfoViaProbe()
        Log.i(TAG, "TIMING bc_probe.chain_info_via_bc: inner ${p.innerMs} ms, round trip ${p.roundTripMs} ms -> ${p.info} (direct height ${direct.height}) raw ${p.raw.take(300)}")
        assertNotNull("bc_probe returned no chain info: ${p.raw}", p.info)
        val h = p.info!!.height
        assertTrue("bc_probe height $h vs direct ${direct.height}", h > 0 && h >= direct.height - 5)
    }

    @Test
    fun t09_stopNode() = runBlocking<Unit> {
        val ms = node.stop()
        Log.i(TAG, "TIMING node stop() $ms ms")
        val err = runCatching { node.cryptarchiaInfo() }.exceptionOrNull()
        Log.i(TAG, "get_cryptarchia_info after stop: $err")
        assertTrue("node still answers after stop: $err", err is BlockchainNode.BlockchainException)
        assertTrue("blockchain_module host went away with the node", BlockchainNode.MODULE in core.loadedModules())
    }

    @Test
    fun t10_hostDeathIsSurfaced() = runBlocking<Unit> {
        val pid = core.moduleStats().first { it.name == BlockchainNode.MODULE }.pid
        val exit = CompletableDeferred<ModuleExit>()
        val watcher = scope.launch { exit.complete(core.moduleExits.first { it.module == BlockchainNode.MODULE }) }
        delay(100) // let the collector subscribe (the flow has no replay)
        val t = SystemClock.elapsedRealtime()
        Process.killProcess(pid.toInt()) // SIGKILL, as an exit(1) from the node's panic hook would end it
        val e = withTimeout(15.seconds) { exit.await() }
        Log.i(TAG, "TIMING host death noticed ${SystemClock.elapsedRealtime() - t} ms after SIGKILL of pid $pid: $e")
        watcher.cancel()
        assertEquals(pid, e.lastPid)
        assertFalse(BlockchainNode.MODULE in core.loadedModules())
        val tc = SystemClock.elapsedRealtime()
        try {
            node.cryptarchiaInfo()
            fail("a call to the dead module succeeded")
        } catch (d: LogosModuleDiedException) {
            Log.i(TAG, "TIMING call to dead module failed after ${SystemClock.elapsedRealtime() - tc} ms: ${d.message}")
        }
        assertTrue("bc_probe went down with blockchain_module", BlockchainNode.PROBE in core.loadedModules())
    }
}
