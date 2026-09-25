package com.fryorcraken.logoslib.demo

import android.content.Context
import android.os.SystemClock
import com.fryorcraken.logoslib.core.LoadDeps
import com.fryorcraken.logoslib.core.LogosCore
import com.fryorcraken.logoslib.core.LogosException
import com.fryorcraken.logoslib.core.LogosJson
import com.fryorcraken.logoslib.core.LogosSubscription
import kotlinx.coroutines.delay
import java.io.File
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/**
 * Blockchain-specific glue over the generic [LogosCore]: drives `blockchain_module`
 * (logos-blockchain-module 4b07e58 around the Logos blockchain node, built at tag
 * 0.3.0-rc.4, so `start(cfg, "")` joins devnet 0.3.0-rc.4) and `bc_probe` (a module that calls
 * blockchain_module through liblogos, docs/research/exp-bc-desktop.md).
 *
 * Call sequence (docs/research/exp-bc-surface.md, "Call sequence for the Kotlin wrapper"):
 * [load] -> [prepareConfig] (generate_user_config + merge_user_config follower mode) ->
 * [subscribeNewBlocks] -> [start] -> poll [cryptarchiaInfo] / [networkInfo] / [timeInfo] /
 * [chainInfoViaProbe] -> [stop].
 *
 * Every blockchain_module method returns `{"success", "value", "error"}`; the value of the
 * info methods is the JSON object as a string. [decode] unwraps both layers.
 *
 * @param nodeDirName directory under filesDir for the node's config, keystore, state, DB and
 *   logs. The node's own defaults are relative to the working directory, so every path the
 *   config names is absolute and app-private.
 */
class BlockchainNode(
    private val core: LogosCore,
    private val context: Context,
    nodeDirName: String = "blockchain",
) {
    companion object {
        const val MODULE = "blockchain_module"
        const val PROBE = "bc_probe"
        const val NEW_BLOCK = "newBlock"

        /** start() returns when every node service is up; a restart replays all blocks since LIB. */
        val START_TIMEOUT: Duration = 10.minutes

        /** Overwatch deadlocks when the node is stopped ~250 ms after start; upstream's test waits 2 s. */
        val MIN_RUN_BEFORE_STOP: Duration = 2.seconds
        val STOP_TIMEOUT: Duration = 60.seconds

        /** HTTP API bound on loopback only (the node always starts it). */
        const val HTTP_ADDR = "127.0.0.1:18080"

        const val GEN_ARGS_ASSET = "devnet-rc4-gen-args.json"
        const val FOLLOWER_ASSET = "follower-mode.extra.yaml"
    }

    data class ChainInfo(val height: Long, val slot: Long, val tip: String, val lib: String, val libSlot: Long, val mode: String)
    data class NetworkInfo(val nPeers: Long, val nConnections: Long, val nPending: Long, val nDiscovered: Long)
    data class TimeInfo(val currentSlot: Long, val currentEpoch: Long, val genesisMs: Long, val slotMs: Long)
    data class ProbeResult(val info: ChainInfo?, val innerMs: Long?, val roundTripMs: Long, val raw: String)
    /** What the demo reads from a newBlock event: the header's slot and parent (it carries no height). */
    data class Block(val slot: Long?, val parent: String?, val bytes: Int)

    class BlockchainException(val method: String, message: String) : LogosException("$MODULE.$method: $message")

    val nodeDir: File = File(context.filesDir, nodeDirName)
    val configFile: File = File(nodeDir, "user_config.yaml")
    val keystoreFile: File = File(nodeDir, "keystore.yaml")

    @Volatile
    var startedAt: Long = 0L
        private set

    // ------------------------------------------------------------------ lifecycle

    /** Loads blockchain_module, then bc_probe (which depends on it), each in its own host. */
    suspend fun load(): Boolean {
        val a = core.loadModule(MODULE, LoadDeps.MODULE_ONLY, timeout = 90.seconds)
        val b = a && core.loadModule(PROBE, LoadDeps.REQUIRED, timeout = 60.seconds)
        return a && b
    }

    /**
     * Writes [configFile] once (generate_user_config refuses when a keystore exists, so an
     * existing config is reused) and merges the follower-mode YAML into it on every call.
     * Returns what was done, for the log.
     *
     * generate_user_config args: `initial_peers`, `net_port` and `blend_port` from the
     * config/blockchain/devnet-rc4-gen-args.json fixture (packaged as an asset);
     * `use_persistence_paths` is false because it would move `output` under liblogos'
     * per-instance persistence directory; instead `output`, `state_path`, `storage_path` and
     * `logs_path` are absolute paths in [nodeDir]; `http_addr` is pinned to [HTTP_ADDR].
     *
     * @param externalAddress optional multiaddr for `external_address`: switches the node's NAT
     *   config from traversal (autonat, UPnP, NAT-PMP, netlink gateway monitor) to static.
     * @param fresh delete [nodeDir] first (new keys, sync from genesis).
     */
    suspend fun prepareConfig(externalAddress: String? = null, fresh: Boolean = false): String {
        val notes = StringBuilder()
        if (fresh && nodeDir.exists()) {
            nodeDir.deleteRecursively()
            notes.append("wiped ${nodeDir.path}; ")
        }
        nodeDir.mkdirs()
        if (configFile.exists() && keystoreFile.exists()) {
            notes.append("reusing ${configFile.path}; ")
        } else {
            configFile.delete()
            keystoreFile.delete()
            val fixture = LogosJson.parse(asset(GEN_ARGS_ASSET)) as Map<*, *>
            val args = linkedMapOf<String, Any?>(
                "initial_peers" to fixture["initial_peers"],
                "net_port" to fixture["net_port"],
                "blend_port" to fixture["blend_port"],
                "http_addr" to HTTP_ADDR,
                "output" to configFile.path,
                "state_path" to File(nodeDir, "state").path,
                "storage_path" to File(nodeDir, "db").path,
                "logs_path" to File(nodeDir, "logs").path,
                "use_persistence_paths" to false,
            )
            if (!externalAddress.isNullOrBlank()) args["external_address"] = externalAddress
            val argsJson = LogosJson.stringify(args)
            val out = decode("generate_user_config", core.call(MODULE, "generate_user_config", LogosJson.array(argsJson), 60.seconds))
            notes.append("generate_user_config -> $out; ")
            check(configFile.exists()) { "generate_user_config reported $out but ${configFile.path} does not exist" }
        }
        val merged = decode(
            "merge_user_config",
            core.call(MODULE, "merge_user_config",
                LogosJson.array(configFile.path, configFile.path, asset(FOLLOWER_ASSET), false, false), 60.seconds),
        )
        notes.append("merge_user_config(follower) -> ${if (merged == "" || merged == null) "no conflicts" else merged}; ")
        notes.append(configSummary())
        return notes.toString()
    }

    /** The lines of [configFile] this demo cares about (bootstrap hold, API, NAT, paths). */
    fun configSummary(): String {
        if (!configFile.exists()) return "no config"
        val lines = configFile.readLines()
        val keys = listOf("prolonged_bootstrap_period", "listen_address", "folder_name", "base_folder", "type:", "external_address", "server:", "port:")
        val picked = lines.filter { l -> keys.any { l.trimStart().startsWith(it) } }.map { it.trim() }.distinct()
        return "config ${configFile.length()} B: " + picked.joinToString(" | ")
    }

    /** `start(config, "")`: the empty deployment is the one compiled into the node (devnet rc.4). */
    suspend fun start(configPath: String = configFile.path, deployment: String = "", timeout: Duration = START_TIMEOUT): Long {
        val t0 = SystemClock.elapsedRealtime()
        decode("start", core.call(MODULE, "start", LogosJson.array(configPath, deployment), timeout))
        startedAt = SystemClock.elapsedRealtime()
        return startedAt - t0
    }

    /** `stop()`, no earlier than [MIN_RUN_BEFORE_STOP] after [start] returned (Overwatch deadlock). */
    suspend fun stop(): Long {
        val ran = SystemClock.elapsedRealtime() - startedAt
        val wait = MIN_RUN_BEFORE_STOP.inWholeMilliseconds - ran
        if (startedAt > 0 && wait > 0) delay(wait)
        val t0 = SystemClock.elapsedRealtime()
        decode("stop", core.call(MODULE, "stop", "[]", STOP_TIMEOUT))
        startedAt = 0L
        return SystemClock.elapsedRealtime() - t0
    }

    suspend fun subscribeNewBlocks(): LogosSubscription = core.subscribe(MODULE, NEW_BLOCK, capacity = 256)

    // ------------------------------------------------------------------ queries

    suspend fun cryptarchiaInfo(): ChainInfo = chainInfo(decode("get_cryptarchia_info", core.call(MODULE, "get_cryptarchia_info")))

    suspend fun networkInfo(): NetworkInfo {
        val m = decode("get_network_info", core.call(MODULE, "get_network_info")) as Map<*, *>
        return NetworkInfo(m.long("n_peers"), m.long("n_connections"), m.long("n_pending_connections"), m.long("n_discovered_peers"))
    }

    suspend fun timeInfo(): TimeInfo {
        val m = decode("get_time_info", core.call(MODULE, "get_time_info")) as Map<*, *>
        return TimeInfo(m.long("current_slot"), m.long("current_epoch"), m.long("genesis_time_unix_ms"), m.long("slot_duration_ms"))
    }

    suspend fun chainId(): String = decode("get_chain_id", core.call(MODULE, "get_chain_id")).toString()

    /**
     * The inter-module hop: bc_probe.chain_info_via_bc() calls blockchain_module's
     * get_cryptarchia_info() from inside bc_probe's host, over liblogos' own QtRO transport
     * (with a capability_module token), and returns `{"success","value","error","ms"}`.
     */
    suspend fun chainInfoViaProbe(): ProbeResult {
        val t0 = SystemClock.elapsedRealtime()
        val raw = core.call(PROBE, "chain_info_via_bc")
        val rt = SystemClock.elapsedRealtime() - t0
        val outer = LogosJson.stringOrNull(raw)?.let { runCatching { LogosJson.parse(it) }.getOrNull() } as? Map<*, *>
        val ms = (outer?.get("ms") as? Number)?.toLong()
        val info = runCatching { chainInfo(decodeResultMap("bc_probe.chain_info_via_bc", outer ?: emptyMap<String, Any?>())) }.getOrNull()
        return ProbeResult(info, ms, rt, raw)
    }

    // ------------------------------------------------------------------ decoding

    /** Unwraps `{"success","value","error"}` (possibly JSON-in-a-string at either level). */
    fun decode(method: String, json: String): Any? {
        var v = LogosJson.parse(json)
        if (v is String && v.trimStart().startsWith("{")) v = runCatching { LogosJson.parse(v as String) }.getOrDefault(v)
        val m = v as? Map<*, *> ?: return v
        return if ("success" in m) decodeResultMap(method, m) else m
    }

    private fun decodeResultMap(method: String, m: Map<*, *>): Any? {
        if (m["success"] != true) throw BlockchainException(method, m["error"]?.toString() ?: "failed: $m")
        val value = m["value"]
        if (value is String) {
            val t = value.trimStart()
            if (t.startsWith("{") || t.startsWith("[")) return runCatching { LogosJson.parse(value) }.getOrDefault(value)
        }
        return value
    }

    private fun chainInfo(v: Any?): ChainInfo {
        val m = v as? Map<*, *> ?: throw BlockchainException("get_cryptarchia_info", "unexpected value $v")
        return ChainInfo(m.long("height"), m.long("slot"), m["tip"]?.toString() ?: "", m["lib"]?.toString() ?: "", m.long("lib_slot"), m["mode"]?.toString() ?: "?")
    }

    /**
     * newBlock's payload is `["{\"block\":\"<block JSON>\"}"]` (the plugin wraps the node's
     * block JSON in an object, logos_blockchain_module.cpp on_new_block_callback), and a
     * literal `null` when the stream ends. The block JSON is
     * `{"header":{"version","parent_block","slot","body_root","proof_of_leadership",...},...}`:
     * no height and no header id, so the chain height comes from get_cryptarchia_info.
     */
    fun parseNewBlock(dataJson: String): Block? {
        val first = runCatching { LogosJson.splitArray(dataJson).firstOrNull() }.getOrNull() ?: return null
        val wrapper = (LogosJson.stringOrNull(first) ?: first).takeIf { it != "null" } ?: return null
        val obj = runCatching { LogosJson.parse(wrapper) }.getOrNull() as? Map<*, *> ?: return null
        val blockJson = obj["block"] as? String ?: return null
        val block = runCatching { LogosJson.parse(blockJson) }.getOrNull() as? Map<*, *>
        val header = block?.get("header") as? Map<*, *>
        return Block(
            slot = (header?.get("slot") as? Number)?.toLong(),
            parent = header?.get("parent_block")?.toString(),
            bytes = blockJson.length,
        )
    }

    private fun Map<*, *>.long(key: String): Long = when (val v = this[key]) {
        is Number -> v.toLong()
        is String -> v.toLongOrNull() ?: -1
        else -> -1
    }

    private fun asset(name: String): String = context.assets.open(name).use { it.readBytes().toString(Charsets.UTF_8) }
}
