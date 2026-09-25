package com.fryorcraken.logoslib.demo

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fryorcraken.logoslib.core.RuntimeState
import com.fryorcraken.logoslib.demo.BlockchainModel.Phase

/**
 * Demo of :logos-core. M4: start liblogos in this process, load `hello_module` (which runs in
 * its own liblogos_host_qt.so child), call `ping`, fire an event and show it arriving.
 * M5/M6 (Blockchain section): load `blockchain_module` + `bc_probe`, generate the node config,
 * start the Logos blockchain node (devnet 0.3.0-rc.4, follower mode) and show it syncing,
 * plus the bc_probe -> blockchain_module inter-module call.
 * All work runs in coroutines (see [DemoModel], [BlockchainModel]); nothing blocks the UI thread.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Before anything creates the (process-wide) LogosCore.
        intent.getStringExtra("log_level")?.let { DemoModel.logLevel = it }
        setContent { DemoScreen() }
        if (savedInstanceState == null) handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /**
     * `--ez autorun true`: the M4 sequence without taps. `--ez bc_autorun true` (with optional
     * `--ez bc_fresh true`, `--es bc_external <multiaddr>`, `--ei bc_sync_timeout <s>`): the
     * blockchain sequence (devnet follower). Adding `--es bc_config <node.yaml>
     * --es bc_deployment <deployment.yaml> [--ei bc_min_height <n>]` starts that config
     * instead (the offline standalone chain). `--es bc_action stop|probe`: act on a running
     * node. `--es log_level debug` (first launch only): LOGOS_LOG_LEVEL for the runtime.
     */
    private fun handle(intent: Intent) {
        if (intent.getBooleanExtra("autorun", false)) DemoModel.autorun(this)
        if (intent.getBooleanExtra("bc_autorun", false)) {
            BlockchainModel.autorun(
                this,
                external = intent.getStringExtra("bc_external"),
                fresh = intent.getBooleanExtra("bc_fresh", false),
                syncTimeoutS = intent.getIntExtra("bc_sync_timeout", 900),
                configPath = intent.getStringExtra("bc_config"),
                deployment = intent.getStringExtra("bc_deployment") ?: "",
                minHeight = intent.getIntExtra("bc_min_height", 3).toLong(),
            )
        }
        when (intent.getStringExtra("bc_action")) {
            "stop" -> BlockchainModel.stop(this)
            "probe" -> BlockchainModel.probeNow(this)
            null -> Unit
            else -> DemoModel.log("unknown bc_action ${intent.getStringExtra("bc_action")}")
        }
    }
}

private val compact = PaddingValues(horizontal = 10.dp, vertical = 2.dp)

@Composable
private fun DemoScreen() {
    val context = LocalContext.current
    val core = DemoModel.core(context)
    val state by core.state.collectAsState()
    val busy by DemoModel.busy.collectAsState()
    val known by DemoModel.known.collectAsState()
    val loaded by DemoModel.loaded.collectAsState()
    val ping by DemoModel.lastPing.collectAsState()
    val event by DemoModel.lastEvent.collectAsState()
    val log by DemoModel.log.collectAsState()
    val listState = rememberLazyListState()
    LaunchedEffect(log.size) {
        if (log.isNotEmpty()) listState.animateScrollToItem(log.size - 1)
    }
    val running = state == RuntimeState.RUNNING

    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(modifier = Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Logos Core Demo", style = MaterialTheme.typography.titleLarge)
                Text("Runtime: $state${if (busy) " (busy)" else ""}")
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Button(onClick = { DemoModel.start(context) }, enabled = state == RuntimeState.NEW && !busy, contentPadding = compact) { Text("Start") }
                    Button(onClick = { DemoModel.loadHello(context) }, enabled = running && !busy, contentPadding = compact) { Text("Load hello") }
                    Button(onClick = { DemoModel.stop(context) }, enabled = running && !busy, contentPadding = compact) { Text("Stop") }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    val helloUp = running && DemoModel.HELLO in loaded
                    Button(onClick = { DemoModel.ping(context) }, enabled = helloUp && !busy, contentPadding = compact) { Text("Ping") }
                    Button(onClick = { DemoModel.fire(context) }, enabled = helloUp && !busy, contentPadding = compact) { Text("Fire") }
                    Button(onClick = { DemoModel.methods(context) }, enabled = helloUp && !busy, contentPadding = compact) { Text("Methods") }
                }
                Text("Known modules: ${known.joinToString().ifEmpty { "-" }}", fontSize = 12.sp)
                Text("Loaded modules: ${loaded.joinToString().ifEmpty { "-" }}", fontSize = 12.sp)
                Text("Ping: $ping", fontSize = 12.sp)
                Text("Last event: $event", fontSize = 12.sp)
                HorizontalDivider()
                BlockchainSection(running)
                HorizontalDivider()
                LazyColumn(state = listState, modifier = Modifier.fillMaxWidth().weight(1f)) {
                    items(log) { line ->
                        Text(line, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
                    }
                }
            }
        }
    }
}

@Composable
private fun BlockchainSection(runtimeRunning: Boolean) {
    val context = LocalContext.current
    val phase by BlockchainModel.phase.collectAsState()
    val busy by BlockchainModel.busy.collectAsState()
    val chainId by BlockchainModel.chainId.collectAsState()
    val chain by BlockchainModel.chain.collectAsState()
    val net by BlockchainModel.net.collectAsState()
    val time by BlockchainModel.time.collectAsState()
    val probe by BlockchainModel.probe.collectAsState()
    val probeError by BlockchainModel.probeError.collectAsState()
    val blocks by BlockchainModel.newBlocks.collectAsState()
    val lastBlock by BlockchainModel.lastBlock.collectAsState()
    val host by BlockchainModel.host.collectAsState()
    val detail by BlockchainModel.detail.collectAsState()
    val synced by BlockchainModel.syncedAfterMs.collectAsState()

    Text("Blockchain: $phase${if (busy) " (busy)" else ""}", fontWeight = FontWeight.Bold)
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        val canLoad = runtimeRunning && !busy && phase in setOf(Phase.IDLE, Phase.FAILED, Phase.DIED)
        Button(onClick = { BlockchainModel.load(context) }, enabled = canLoad, contentPadding = compact) { Text("Load BC") }
        val canConfig = runtimeRunning && !busy && phase in setOf(Phase.LOADED, Phase.CONFIGURED, Phase.STOPPED, Phase.FAILED)
        Button(onClick = { BlockchainModel.configure(context) }, enabled = canConfig, contentPadding = compact) { Text("Config") }
        val canStart = runtimeRunning && !busy && phase in setOf(Phase.CONFIGURED, Phase.STOPPED)
        Button(onClick = { BlockchainModel.start(context) }, enabled = canStart, contentPadding = compact) { Text("Start node") }
        Button(onClick = { BlockchainModel.stop(context) }, enabled = runtimeRunning && !busy && phase == Phase.RUNNING, contentPadding = compact) { Text("Stop node") }
    }
    val mono = 12.sp
    val lag = if (chain != null && time != null) time!!.currentSlot - chain!!.slot else null
    Text("chain ${chainId}  mode ${chain?.mode ?: "-"}${synced?.let { "  synced after ${it / 1000} s" } ?: ""}", fontSize = mono)
    Text("height ${chain?.height ?: "-"}  tip slot ${chain?.slot ?: "-"} / now ${time?.currentSlot ?: "-"}" +
        (lag?.let { "  (lag $it)" } ?: "") + "  LIB slot ${chain?.libSlot ?: "-"}", fontSize = mono)
    Text("peers ${net?.nPeers ?: "-"}  connections ${net?.nConnections ?: "-"}  pending ${net?.nPending ?: "-"}  discovered ${net?.nDiscovered ?: "-"}", fontSize = mono)
    Text("newBlock events $blocks  last block slot ${lastBlock?.slot ?: "-"}", fontSize = mono)
    Text("via bc_probe: height ${probe?.info?.height ?: "-"}  (bc_probe->blockchain_module ${probe?.innerMs ?: "-"} ms, round trip ${probe?.roundTripMs ?: "-"} ms)" +
        (probeError?.let { "  error: ${it.take(60)}" } ?: ""), fontSize = mono)
    Text("host pid ${host?.pid ?: "-"}  cpu ${host?.cpuPercent?.let { "%.1f".format(it) } ?: "-"}%  rss ${host?.memoryMb?.let { "%.0f".format(it) } ?: "-"} MB", fontSize = mono)
    Text(detail, fontSize = 11.sp, maxLines = 2)
}
