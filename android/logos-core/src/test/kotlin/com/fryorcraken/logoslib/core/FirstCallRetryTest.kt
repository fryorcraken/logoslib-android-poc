package com.fryorcraken.logoslib.core

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

@OptIn(ExperimentalCoroutinesApi::class)
class FirstCallRetryTest {

    @Test
    fun `default answers are not ready`() {
        assertFalse(FirstCallRetry.isNonDefault("\"\""))
        assertFalse(FirstCallRetry.isNonDefault("null"))
        assertFalse(FirstCallRetry.isNonDefault(" "))
        assertTrue(FirstCallRetry.isNonDefault("\"pong\""))
        assertTrue(FirstCallRetry.isNonDefault("0"))
        assertTrue(FirstCallRetry.isNonDefault("false"))
    }

    @Test
    fun `retries until the answer is accepted`() = runTest {
        val answers = ArrayDeque(listOf("\"\"", "\"\"", "\"pong\""))
        var calls = 0
        val r = FirstCallRetry.retryUntil(
            budget = 5.seconds, backoff = 25.milliseconds, accept = FirstCallRetry::isNonDefault,
            timeSource = testScheduler.timeSource,
        ) { calls++; answers.removeFirst() }
        assertEquals("\"pong\"", r)
        assertEquals(3, calls)
        assertEquals(50L, currentTime) // two backoffs
    }

    @Test
    fun `returns the last answer when the budget runs out`() = runTest {
        var calls = 0
        val r = FirstCallRetry.retryUntil(
            budget = 100.milliseconds, backoff = 25.milliseconds, accept = FirstCallRetry::isNonDefault,
            timeSource = testScheduler.timeSource,
        ) { calls++; "\"\"" }
        assertEquals("\"\"", r)
        assertEquals(4, calls) // at t = 0, 25, 50, 75; the next would start at the 100 ms budget
    }

    @Test
    fun `an in-flight attempt is not cut short by the budget`() = runTest {
        val r = FirstCallRetry.retryUntil(
            budget = 10.milliseconds, backoff = 5.milliseconds, accept = { it == "slow" },
            timeSource = testScheduler.timeSource,
        ) { delay(1000); "slow" }
        assertEquals("slow", r)
    }

    @Test
    fun `retryable call errors are retried, others propagate`() = runTest {
        var calls = 0
        val r = FirstCallRetry.retryUntil(
            budget = 1.seconds, backoff = 10.milliseconds, accept = FirstCallRetry::isNonDefault,
            timeSource = testScheduler.timeSource,
        ) {
            calls++
            if (calls < 3) throw LogosCallException("m", "x", "object_unavailable", "not yet", null, "{}")
            "1"
        }
        assertEquals("1", r)
        assertEquals(3, calls)
    }

    @Test
    fun `a deadline error is not retried`() {
        var calls = 0
        assertThrows(LogosTimeoutException::class.java) {
            runBlocking {
                FirstCallRetry.retryUntil<String>(1.seconds, 10.milliseconds, { true }) {
                    calls++
                    throw LogosTimeoutException("no answer")
                }
            }
        }
        assertEquals(1, calls)
    }

    @Test
    fun `the last retryable error is rethrown when the budget runs out`() {
        assertThrows(LogosCallException::class.java) {
            runBlocking {
                FirstCallRetry.retryUntil<String>(30.milliseconds, 10.milliseconds, { true }) {
                    throw LogosCallException("m", "x", "object_unavailable", "never", null, "{}")
                }
            }
        }
    }
}
