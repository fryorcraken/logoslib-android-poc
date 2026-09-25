package com.fryorcraken.logoslib.core

import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * Tunables for [LogosCore]. The defaults follow the host call policy measured on desktop
 * (docs/research/exp-desktop-harness.md, "Recommended Kotlin/JNI threading and timeout policy").
 *
 * @property callTimeout Kotlin deadline of [LogosCore.call], including the wait for the
 *   module's single in-flight slot. liblogos' own timer only starts once the Qt thread picks
 *   the call up, so the Kotlin deadline is the one that is honest.
 * @property lpTimeoutMargin added to the Kotlin deadline when passing `timeout_ms` to
 *   `lp_invoke_async`, so liblogos never times out a call Kotlin is still waiting for.
 * @property loadTimeout Kotlin deadline of [LogosCore.loadModule] (the native load keeps
 *   running if it elapses; liblogos itself gives a host 10 s to report per module).
 * @property startTimeout how long [LogosCore.start] waits for the Qt loop to come up
 *   (includes bringing up capability_module in its child process).
 * @property firstCallRetryBudget / firstCallRetryBackoff drive [LogosCore.callWithRetry].
 * @property armTimeout default for [LogosCore.awaitArmed]; pending subscriptions are polled
 *   on a 250 ms .. 5 s backoff by logos-protocol.
 * @property originModule the `origin_module` this app presents in `lp_client_create`.
 * @property redirectStdioToLogcat pipe the process' stdout/stderr (spdlog, liblogos and the
 *   module host children, which inherit them) into logcat under tag `logos-stdio`.
 * @property readOnlyModules make the extracted module directories read-only.
 */
public data class LogosConfig(
    val callTimeout: Duration = 20.seconds,
    val lpTimeoutMargin: Duration = 1.seconds,
    val loadTimeout: Duration = 60.seconds,
    val startTimeout: Duration = 30.seconds,
    val firstCallRetryBudget: Duration = 5.seconds,
    val firstCallRetryBackoff: Duration = 25.milliseconds,
    val armTimeout: Duration = 10.seconds,
    val originModule: String = "android_host",
    val redirectStdioToLogcat: Boolean = true,
    val readOnlyModules: Boolean = true,
)
