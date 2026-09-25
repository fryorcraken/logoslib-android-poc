package com.fryorcraken.logoslib.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlin.time.Duration
import kotlin.time.TimeSource

/**
 * The first-call race (docs/research/exp-desktop-harness.md, experiment X7 (b)).
 *
 * After `logos_core_load_module` returns on a non-Qt thread, core registers the new module's
 * token with capability_module *asynchronously*. Until that lands, a call that crosses a
 * module-to-module edge is rejected inside the module and the typed wrapper answers its
 * **default value** -- `""` for a string, with success and no error. On desktop 13 of 20
 * first calls hit it; all were good ~20 ms later. Direct host-to-module calls were not
 * affected, but retrying an idempotent probe costs nothing.
 *
 * Only retry **idempotent** methods: a retried call runs again inside the module.
 */
public object FirstCallRetry {

    /** Default "not ready yet" test: `null` and `""` are the wrappers' default answers. */
    public fun isNonDefault(json: String): Boolean {
        val t = json.trim()
        return t.isNotEmpty() && t != "null" && t != "\"\""
    }

    /**
     * Runs [attempt] until [accept] is true, sleeping [backoff] between attempts, and starts
     * no new attempt once [budget] has elapsed (an attempt that is in flight is never
     * cut short by the budget; bound it with its own timeout).
     *
     * Exceptions for which [retryOn] is true are retried too. When the budget runs out the
     * last result is returned even if not accepted (the caller sees what the module said),
     * or the last exception is rethrown. Cancellation is never swallowed.
     */
    public suspend fun <T> retryUntil(
        budget: Duration,
        backoff: Duration,
        accept: (T) -> Boolean,
        retryOn: (Throwable) -> Boolean = { it is LogosCallException },
        timeSource: TimeSource = TimeSource.Monotonic,
        attempt: suspend (attemptNumber: Int) -> T,
    ): T {
        val start = timeSource.markNow()
        var n = 0
        while (true) {
            n++
            val result = try {
                Result.success(attempt(n))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                if (!retryOn(e)) throw e
                Result.failure(e)
            }
            if (result.isSuccess && accept(result.getOrThrow())) return result.getOrThrow()
            // The next attempt would start at or past the budget: give the caller what we have.
            if (start.elapsedNow() + backoff >= budget) return result.getOrThrow()
            delay(backoff)
        }
    }
}
