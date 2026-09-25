package com.fryorcraken.logoslib.core

/** Base class for failures reported by [LogosCore]. */
public open class LogosException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * A module call failed with liblogos' canonical error object
 * `{"code": "...", "message": "...", "origin": "..."}` (logos_protocol.h), e.g.
 * `object_unavailable`, `timeout`, a rejected auth token or `MODULE_NOT_LOADED`.
 *
 * Note what is *not* an error at this boundary: an unknown method name answers `null`
 * with success, indistinguishable from a method that returns null (logos_protocol.h,
 * lp_invoke_async). Validate names with [LogosCore.methods] if that matters.
 */
public class LogosCallException(
    public val module: String,
    public val method: String,
    public val code: String,
    public val detail: String,
    public val origin: String?,
    public val errorJson: String,
) : LogosException("$module.$method failed: $code: $detail") {

    public companion object {
        /** Builds the exception from the error JSON an `lp_invoke_async` callback delivered. */
        public fun fromErrorJson(module: String, method: String, errorJson: String): LogosCallException {
            val obj = runCatching { LogosJson.parse(errorJson) }.getOrNull() as? Map<*, *>
            val code = obj?.get("code")?.toString() ?: "unknown"
            val msg = obj?.get("message")?.toString() ?: errorJson
            val origin = obj?.get("origin")?.toString()
            return LogosCallException(module, method, code, msg, origin, errorJson)
        }
    }
}

/**
 * The Kotlin-side deadline of a [LogosCore] operation elapsed. The native operation is not
 * cancelled (liblogos cannot cancel a dispatched call): the module may still be busy with it,
 * and a late result is dropped.
 */
public class LogosTimeoutException(message: String) : LogosException(message)
