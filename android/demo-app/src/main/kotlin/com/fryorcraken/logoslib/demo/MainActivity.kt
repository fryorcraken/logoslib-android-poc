package com.fryorcraken.logoslib.demo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fryorcraken.logoslib.core.RuntimeState

/**
 * M4 demo: start liblogos in this process, load `hello_module` (which runs in its own
 * liblogos_host_qt.so child), call `ping`, fire an event and show it arriving.
 * All work runs in coroutines (see [DemoModel]); nothing blocks the UI thread.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { DemoScreen() }
        // `am start ... --ez autorun true`: run the whole M4 sequence without taps.
        if (savedInstanceState == null && intent.getBooleanExtra("autorun", false)) {
            DemoModel.autorun(this)
        }
    }
}

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
            Column(modifier = Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Logos Core Demo", style = MaterialTheme.typography.headlineSmall)
                Text("Runtime: $state${if (busy) " (busy)" else ""}")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { DemoModel.start(context) }, enabled = state == RuntimeState.NEW && !busy) { Text("Start") }
                    Button(onClick = { DemoModel.loadHello(context) }, enabled = running && !busy) { Text("Load hello") }
                    Button(onClick = { DemoModel.stop(context) }, enabled = running && !busy) { Text("Stop") }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    val helloUp = running && DemoModel.HELLO in loaded
                    Button(onClick = { DemoModel.ping(context) }, enabled = helloUp && !busy) { Text("Ping") }
                    Button(onClick = { DemoModel.fire(context) }, enabled = helloUp && !busy) { Text("Fire") }
                    Button(onClick = { DemoModel.methods(context) }, enabled = helloUp && !busy) { Text("Methods") }
                }
                Text("Known modules: ${known.joinToString().ifEmpty { "-" }}")
                Text("Loaded modules: ${loaded.joinToString().ifEmpty { "-" }}")
                Text("Ping: $ping")
                Text("Last event: $event")
                HorizontalDivider()
                LazyColumn(state = listState, modifier = Modifier.fillMaxWidth().weight(1f)) {
                    items(log) { line ->
                        Text(line, fontFamily = FontFamily.Monospace, fontSize = 11.sp)
                    }
                }
            }
        }
    }
}
