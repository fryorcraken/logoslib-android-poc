package com.fryorcraken.logoslib.core

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlin.time.Duration

/**
 * One event emitted by a module, as delivered by `lp_subscribe`.
 *
 * @property dataJson the payload, a JSON array (logos_protocol.h), e.g. `["tag-1"]`.
 */
public data class LogosEvent(
    val module: String,
    val name: String,
    val dataJson: String,
) {
    /** The payload's top-level elements, each still JSON-encoded (see [LogosJson.splitArray]). */
    public val args: List<String> get() = LogosJson.splitArray(dataJson)

    /** Element [index] decoded as a string if it is a JSON string, else its raw JSON. */
    public fun argAsString(index: Int): String? =
        args.getOrNull(index)?.let { LogosJson.stringOrNull(it) ?: it }
}

/**
 * Subscription state of one target module, from `lp_client_set_subscription_status_cb`.
 * It is per module, not per event: every subscription to a module shares one handle.
 * A [State.LOST] followed by [State.ARMED] with a higher [generation] means events were
 * missed while the provider was away.
 */
public data class SubscriptionStatus(
    val state: State,
    val generation: Long = 0,
    val reason: String? = null,
) {
    public enum class State(internal val native: Int) {
        /** No subscription has armed yet (or none was made). */
        NONE(0),
        ARMED(1),
        LOST(2),
        ABANDONED(3),
        HELD(4);

        internal companion object {
            fun fromNative(v: Int): State = entries.firstOrNull { it.native == v } ?: NONE
        }
    }
}

/**
 * A live `lp_subscribe` registration, returned by [LogosCore.subscribe].
 *
 * [events] is backed by a buffered channel: collect it from **one** collector. Close the
 * subscription (or use [LogosCore.events], which does it for you) to release it.
 */
public class LogosSubscription internal constructor(
    public val module: String,
    public val event: String,
    internal val listenerId: Long,
    private val channel: Channel<LogosEvent>,
    private val core: LogosCore,
    private val onClose: (LogosSubscription) -> Unit,
) : AutoCloseable {

    /** Events in arrival order. Completes when the subscription or the runtime is closed. */
    public val events: Flow<LogosEvent> = channel.receiveAsFlow()

    /** Suspends until this module's subscriptions are armed (see [LogosCore.awaitArmed]). */
    public suspend fun awaitArmed(timeout: Duration = core.config.armTimeout): SubscriptionStatus =
        core.awaitArmed(module, timeout)

    /** Cancels the native subscription; after it returns no further events are delivered. */
    override fun close() {
        onClose(this)
    }
}
