package com.fryorcraken.logoslib.demo

import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.fryorcraken.logoslib.core.LogosModuleDiedException
import com.fryorcraken.logoslib.core.LogosSubscription
import com.fryorcraken.logoslib.core.ModuleStats
import com.fryorcraken.logoslib.demo.BlockchainNode.Block
import com.fryorcraken.logoslib.demo.BlockchainNode.ChainInfo
import com.fryorcraken.logoslib.demo.BlockchainNode.NetworkInfo
import com.fryorcraken.logoslib.demo.BlockchainNode.ProbeResult
import com.fryorcraken.logoslib.demo.BlockchainNode.TimeInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.time.Duration.Companion.seconds

/**
 * Process-wide state of the demo's Blockchain section (blockchain_module + bc_probe), next to
 * [DemoModel]'s hello_module part. Nothing here blocks the UI thread: every step is a
 * coroutine, and the node's start() (which blocks for as long as the node takes to bring its
 * services up) only occupies blockchain_module's call slot.
 *
 * Unattended runs (scripts/android/run-m5.sh):
 * `am start -n com.fryorcraken.logoslib.demo/.MainActivity --ez bc_autorun true`
 * [--ez bc_fresh true] [--es bc_external /ip4/.../udp/3000/quic-v1] [--ei bc_sync_timeout 900]
 * logs `BC ...` lines under tag LogosDemo and ends with `BC AUTORUN OK` / `BC AUTORUN FAILED`;
 * the node keeps running. `--es bc_action stop` (a second am start) stops it.
 */
object BlockchainModel {
    enum class Phase { IDLE, LOADING, LOADED, CONFIGURING, CONFIGURED, STARTING, RUNNING, STOPPING, STOPPED, DIED, FAILED }

    private const val TAG = "LogosDemo"

    /** "At the tip": the tip's slot is within this many slots (1 s each) of the wall-clock slot. */
    const val SYNC_LAG_SLOTS = 180L
    private const val POLL_MS = 2_000L
    private const val STATUS_EVERY_MS = 10_000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    val phase = MutableStateFlow(Phase.IDLE)
    val busy = MutableStateFlow(false)
    val chainId = MutableStateFlow("-")
    val chain = MutableStateFlow<ChainInfo?>(null)
    val net = MutableStateFlow<NetworkInfo?>(null)
    val time = MutableStateFlow<TimeInfo?>(null)
    val probe = MutableStateFlow<ProbeResult?>(null)
    val probeError = MutableStateFlow<String?>(null)
    val newBlocks = MutableStateFlow(0)
    val lastBlock = MutableStateFlow<Block?>(null)
    val host = MutableStateFlow<ModuleStats?>(null)
    val probeHost = MutableStateFlow<ModuleStats?>(null)
    val detail = MutableStateFlow("-")
    val syncedAfterMs = MutableStateFlow<Long?>(null)

    @Volatile private var node: BlockchainNode? = null
    private var sub: LogosSubscription? = null
    private var pollJob: Job? = null
    private var deathWatch: Job? = null
    private var startCalledAt = 0L
    private var firstPeerAt = 0L
    private var firstBlockAt = 0L

    private fun log(msg: String) = DemoModel.log("BC $msg")

    fun node(context: Context): BlockchainNode =
        node ?: synchronized(this) { node ?: BlockchainNode(DemoModel.core(context), context.applicationContext).also { node = it } }

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
                detail.value = "$name failed: ${e.message}"
                log("$name FAILED: ${e.javaClass.simpleName}: ${e.message}")
                Log.e(TAG, "BC $name failed", e)
                if (e is LogosModuleDiedException) phase.value = Phase.DIED
                else if (phase.value in setOf(Phase.LOADING, Phase.CONFIGURING, Phase.STARTING, Phase.STOPPING)) phase.value = Phase.FAILED
            } finally {
                log("$name took ${SystemClock.elapsedRealtime() - t} ms")
                busy.value = false
            }
        }
    }

    fun load(context: Context) = op("load") { doLoad(context) }
    fun configure(context: Context, external: String? = null, fresh: Boolean = false) = op("config") { doConfigure(context, external, fresh) }
    fun start(context: Context) = op("start") { doStart(context) }
    fun stop(context: Context) = op("stop") { doStop(context) }
    fun probeNow(context: Context) = scope.launch { pollProbe(node(context)) }

    /**
     * start runtime (if needed) -> load -> config -> start node -> wait for peers, the tip,
     * a newBlock event and a bc_probe answer. The node keeps running afterwards.
     *
     * With [configPath] (`--es bc_config <path> --es bc_deployment <path>`) the config step is
     * skipped and the node starts from that config and deployment instead: the offline
     * standalone single-node chain, which has no peers and proposes its own blocks (with an
     * on-device PoL proof each). Done then means: height >= [minHeight], a newBlock event and
     * a bc_probe answer.
     */
    fun autorun(
        context: Context,
        external: String?,
        fresh: Boolean,
        syncTimeoutS: Int,
        configPath: String? = null,
        deployment: String = "",
        minHeight: Long = 3,
    ) = op("autorun") {
        try {
            val core = DemoModel.core(context)
            if (!core.isRunning) DemoModel.startBlocking(context)
            if (phase.value < Phase.LOADED || phase.value == Phase.DIED) doLoad(context)
            if (configPath == null) doConfigure(context, external, fresh) else log("config: using $configPath with deployment '$deployment'")
            doStart(context, configPath ?: node(context).configFile.path, deployment)
            val standalone = configPath != null
            fun done(): Boolean = newBlocks.value > 0 && (probe.value?.info?.height ?: 0) > 0 &&
                if (standalone) (chain.value?.height ?: 0) >= minHeight
                else (net.value?.nPeers ?: 0) > 0 && syncedAfterMs.value != null
            val t0 = SystemClock.elapsedRealtime()
            val deadline = t0 + syncTimeoutS * 1000L
            while (SystemClock.elapsedRealtime() < deadline) {
                if (done() || phase.value == Phase.DIED) break
                delay(1_000)
            }
            val summary = "peers=${net.value?.nPeers} height=${chain.value?.height} tip_slot=${chain.value?.slot} " +
                "current_slot=${time.value?.currentSlot} synced_after_ms=${syncedAfterMs.value} newBlock=${newBlocks.value} " +
                "probe_height=${probe.value?.info?.height} mode=${chain.value?.mode}${if (standalone) " standalone" else ""}"
            val ok = phase.value == Phase.RUNNING && done()
            log(if (ok) "AUTORUN OK ($summary)" else "AUTORUN FAILED: phase=${phase.value} $summary")
        } catch (e: Exception) {
            log("AUTORUN FAILED: ${e.javaClass.simpleName}: ${e.message}")
            throw e
        }
    }

    // ------------------------------------------------------------------ steps

    private suspend fun doLoad(context: Context) {
        val core = DemoModel.core(context)
        watchDeaths(context)
        phase.value = Phase.LOADING
        val n = node(context)
        val t = SystemClock.elapsedRealtime()
        val ok = n.load()
        val children = core.moduleStats()
        log("load ${BlockchainNode.MODULE} + ${BlockchainNode.PROBE} -> $ok in ${SystemClock.elapsedRealtime() - t} ms; " +
            "hosts: ${children.joinToString { "${it.name}=pid ${it.pid}" }}")
        DemoModel.refreshModules(context)
        check(ok) { "loadModule failed (see logos-stdio)" }
        // Subscribe after the load and before start(): start() subscribes the node's block
        // streams itself and the first blocks arrive within seconds.
        if (sub == null) {
            val s = n.subscribeNewBlocks()
            sub = s
            scope.launch {
                s.events.collect { ev ->
                    val b = n.parseNewBlock(ev.dataJson)
                    if (b == null) {
                        log("newBlock stream ended (${ev.dataJson.take(80)})")
                        return@collect
                    }
                    val c = newBlocks.value + 1
                    newBlocks.value = c
                    lastBlock.value = b
                    if (c == 1) {
                        firstBlockAt = SystemClock.elapsedRealtime()
                        log("first newBlock event after ${if (startCalledAt > 0) firstBlockAt - startCalledAt else -1} ms since start(): " +
                            "slot=${b.slot} (${b.bytes} B block JSON; the header has no height) payload ${ev.dataJson.take(300)}")
                    } else if (c % 500 == 0) {
                        log("newBlock #$c slot=${b.slot}")
                    }
                }
            }
            val st = s.awaitArmed(15.seconds)
            log("subscribed ${BlockchainNode.MODULE}.${BlockchainNode.NEW_BLOCK}: ${st.state} (generation ${st.generation})")
        }
        phase.value = Phase.LOADED
        detail.value = "loaded: ${core.loadedModules()}"
    }

    private suspend fun doConfigure(context: Context, external: String?, fresh: Boolean) {
        check(phase.value !in setOf(Phase.STARTING, Phase.RUNNING, Phase.STOPPING)) { "stop the node first" }
        phase.value = Phase.CONFIGURING
        val n = node(context)
        val notes = n.prepareConfig(externalAddress = external, fresh = fresh)
        log("config: $notes")
        phase.value = Phase.CONFIGURED
        detail.value = "config ${n.configFile.path}"
    }

    private suspend fun doStart(context: Context, configPath: String = node(context).configFile.path, deployment: String = "") {
        val n = node(context)
        check(java.io.File(configPath).exists()) { "no config at $configPath (Config first)" }
        phase.value = Phase.STARTING
        syncedAfterMs.value = null
        firstPeerAt = 0L
        startCalledAt = SystemClock.elapsedRealtime()
        detail.value = "start() in progress (the node brings its services up)"
        log("start($configPath, \"$deployment\") ...")
        val ms = n.start(configPath, deployment)
        log("start() returned after $ms ms")
        phase.value = Phase.RUNNING
        runCatching { chainId.value = n.chainId() }.onSuccess { log("chain id ${chainId.value}") }
        detail.value = "running"
        startPolling(context)
    }

    private suspend fun doStop(context: Context) {
        val n = node(context)
        phase.value = Phase.STOPPING
        pollJob?.cancel()
        val ms = n.stop()
        log("stop() returned after $ms ms (node ran ${(SystemClock.elapsedRealtime() - startCalledAt) / 1000} s)")
        phase.value = Phase.STOPPED
        detail.value = "stopped"
        val stats = DemoModel.core(context).moduleStats().firstOrNull { it.name == BlockchainNode.MODULE }
        log("after stop: ${BlockchainNode.MODULE} host still loaded: pid ${stats?.pid}, rss ${stats?.memoryMb?.let { "%.0f".format(it) }} MB")
    }

    /** Used by the runtime Stop: stops the node first if it runs (errors are logged, not thrown). */
    suspend fun stopNodeIfRunning(context: Context) {
        if (phase.value != Phase.RUNNING) return
        runCatching { doStop(context) }.onFailure { log("stop before runtime stop failed: ${it.message}") }
        sub?.close()
        sub = null
    }

    // ------------------------------------------------------------------ monitoring

    private fun watchDeaths(context: Context) {
        if (deathWatch != null) return
        val core = DemoModel.core(context)
        deathWatch = scope.launch {
            core.moduleExits.collect { e ->
                log("HOST DIED ${e.module}: pid ${e.lastPid}, up ${e.uptimeMillis} ms (${e.reason})")
                DemoModel.refreshModules(context)
                if (e.module == BlockchainNode.MODULE) {
                    phase.value = Phase.DIED
                    detail.value = "${e.module} host died (pid ${e.lastPid}); Load BC to reload"
                    pollJob?.cancel()
                    sub?.close()
                    sub = null
                }
            }
        }
    }

    private fun startPolling(context: Context) {
        pollJob?.cancel()
        val n = node(context)
        val core = DemoModel.core(context)
        pollJob = scope.launch {
            var lastStatus = 0L
            while (isActive && phase.value == Phase.RUNNING) {
                runCatching { chain.value = n.cryptarchiaInfo() }.onFailure { noteError("get_cryptarchia_info", it) }
                runCatching { net.value = n.networkInfo() }.onFailure { noteError("get_network_info", it) }
                runCatching { time.value = n.timeInfo() }.onFailure { noteError("get_time_info", it) }
                pollProbe(n)
                runCatching {
                    val stats = core.moduleStats()
                    host.value = stats.firstOrNull { it.name == BlockchainNode.MODULE }
                    probeHost.value = stats.firstOrNull { it.name == BlockchainNode.PROBE }
                }
                val now = SystemClock.elapsedRealtime()
                val peers = net.value?.nPeers ?: 0
                if (peers > 0 && firstPeerAt == 0L) {
                    firstPeerAt = now
                    log("first peer after ${now - startCalledAt} ms since start(): ${net.value}")
                }
                val c = chain.value
                val cur = time.value?.currentSlot
                if (syncedAfterMs.value == null && c != null && cur != null && c.height > 0 && cur - c.slot <= SYNC_LAG_SLOTS) {
                    syncedAfterMs.value = now - startCalledAt
                    log("SYNCED height=${c.height} tip_slot=${c.slot} current_slot=$cur lag=${cur - c.slot} slots " +
                        "after ${now - startCalledAt} ms since start(); peers=$peers newBlock=${newBlocks.value}")
                }
                if (now - lastStatus >= STATUS_EVERY_MS) {
                    lastStatus = now
                    val h = host.value
                    log("STATUS mode=${c?.mode} height=${c?.height} tip_slot=${c?.slot} current_slot=$cur " +
                        "lib_slot=${c?.libSlot} peers=$peers conns=${net.value?.nConnections} " +
                        "pending=${net.value?.nPending} discovered=${net.value?.nDiscovered} newBlock=${newBlocks.value} " +
                        "probe_height=${probe.value?.info?.height} probe_ms=${probe.value?.innerMs}/${probe.value?.roundTripMs} " +
                        "host pid=${h?.pid} cpu=${h?.cpuPercent?.let { "%.1f".format(it) }}% rss=${h?.memoryMb?.let { "%.1f".format(it) }}MB")
                }
                delay(POLL_MS)
            }
        }
    }

    private suspend fun pollProbe(n: BlockchainNode) {
        runCatching { n.chainInfoViaProbe() }
            .onSuccess {
                probe.value = it
                probeError.value = if (it.info == null) it.raw.take(160) else null
            }
            .onFailure { noteError("bc_probe.chain_info_via_bc", it); probeError.value = it.message }
    }

    private var lastErrorLog = 0L
    private fun noteError(what: String, t: Throwable) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastErrorLog > 5_000) {
            lastErrorLog = now
            log("$what failed: ${t.javaClass.simpleName}: ${t.message}")
        }
    }
}
