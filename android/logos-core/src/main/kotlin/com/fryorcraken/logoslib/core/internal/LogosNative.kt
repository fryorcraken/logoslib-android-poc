package com.fryorcraken.logoslib.core.internal

import android.util.Log

/**
 * JNI surface of liblogos_jni.so (android/logos-core/src/main/cpp/logos_jni.cpp).
 *
 * Every `external` below maps to a `Java_com_fryorcraken_logoslib_core_internal_LogosNative_*`
 * entry point; the `on*` functions are called *from* native code (method IDs cached in the
 * shim's JNI_OnLoad, which is also why this class must not be renamed or minified; see
 * consumer-rules.pro). Members are public on purpose: `internal` members get mangled JVM
 * names, which JNI could not find.
 *
 * Threading: [nativeRun] blocks the dedicated `logos-qt` thread for the life of the runtime.
 * The callbacks arrive on that Qt thread (or an internal protocol thread) and must only hand
 * off -- complete a deferred, `trySend` to a channel -- never block or call back into liblogos.
 */
internal object LogosNative {

    // ---- lifecycle (qt_loop.cpp) --------------------------------------------------------

    /**
     * Runs QCoreApplication + logos_core_init/add_modules_dir/set_persistence_base_path/start
     * and exec() on the CALLING thread; returns exec()'s code once [nativeStop] quit the loop
     * (after unsubscribing, destroying lp clients and logos_core_cleanup()). Calls [onReady]
     * from inside the running loop. Returns a negative value if a runtime already ran.
     */
    @JvmStatic external fun nativeRun(modulesDir: String, persistDir: String, appName: String, origin: String): Int

    /** Posts a quit to the Qt loop (queued). False if no loop is running. */
    @JvmStatic external fun nativeStop(): Boolean

    @JvmStatic external fun nativeIsRunning(): Boolean

    /** Pipes stdout/stderr into logcat (idempotent). */
    @JvmStatic external fun nativeRedirectStdio(tag: String): Boolean

    /** Return code of QtCore's JNI_OnLoad(realVM) as called from our JNI_OnLoad (-1 = JNI_ERR, expected). */
    @JvmStatic external fun nativeQtCorePrimeResult(): Int

    @JvmStatic external fun nativeQtVersion(): String

    @JvmStatic external fun nativeProtocolVersion(): String

    // ---- logos_core_* -----------------------------------------------------------------

    @JvmStatic external fun nativeKnownModules(): Array<String>

    @JvmStatic external fun nativeLoadedModules(): Array<String>

    /** logos_core_get_modules_info(): JSON array, or null. */
    @JvmStatic external fun nativeModulesInfo(): String?

    /** logos_core_load_module(name, deps): 1 on success. BLOCKS for the whole host bring-up. */
    @JvmStatic external fun nativeLoadModule(name: String, deps: Int): Int

    @JvmStatic external fun nativeUnloadModule(name: String, withDependents: Boolean): Int

    // ---- lp_* -------------------------------------------------------------------------

    /**
     * lp_invoke_async on the cached client for [module] (created on first use; that creation
     * blocks until the Qt thread runs it). Returns LP_OK (0) when dispatched -- the outcome
     * then arrives through [onInvokeResult] with the same [callId] -- or a negative code:
     * LP_ERR_* (-1..-4), [ERR_NOT_RUNNING], [ERR_NO_CLIENT].
     */
    @JvmStatic external fun nativeInvokeAsync(module: String, method: String, argsJson: String, timeoutMs: Int, callId: Long): Int

    /** Forgets [callId]; a result arriving later is dropped natively. True if it was pending. */
    @JvmStatic external fun nativeCancelCall(callId: Long): Boolean

    /** lp_subscribe(module, event); events arrive through [onEvent] with [listenerId]. 0 on success. */
    @JvmStatic external fun nativeSubscribe(module: String, event: String, listenerId: Long): Int

    /** lp_unsubscribe for [listenerId]; after it returns no further events for it fire. */
    @JvmStatic external fun nativeUnsubscribe(listenerId: Long)

    /** lp_pending_subscriptions for [module]'s client (diagnostics), or null if there is none. */
    @JvmStatic external fun nativePendingSubscriptions(module: String): String?

    const val ERR_NOT_RUNNING = -100
    const val ERR_NO_CLIENT = -101

    // ---- callbacks from native ----------------------------------------------------------

    @Volatile
    var sink: NativeSink? = null

    interface NativeSink {
        fun ready()
        fun invokeResult(callId: Long, ok: Boolean, json: String)
        fun event(listenerId: Long, event: String, dataJson: String)
        fun subscriptionStatus(module: String, state: Int, generation: Long, reason: String?)
    }

    @JvmStatic
    fun onReady() = dispatch("onReady") { it.ready() }

    @JvmStatic
    fun onInvokeResult(callId: Long, ok: Boolean, json: String) =
        dispatch("onInvokeResult") { it.invokeResult(callId, ok, json) }

    @JvmStatic
    fun onEvent(listenerId: Long, event: String, dataJson: String) =
        dispatch("onEvent") { it.event(listenerId, event, dataJson) }

    @JvmStatic
    fun onSubscriptionStatus(module: String, state: Int, generation: Long, reason: String?) =
        dispatch("onSubscriptionStatus") { it.subscriptionStatus(module, state, generation, reason) }

    private inline fun dispatch(what: String, block: (NativeSink) -> Unit) {
        val s = sink ?: return
        // Never let an exception unwind into the Qt event loop.
        try {
            block(s)
        } catch (t: Throwable) {
            Log.e(TAG, "$what callback threw", t)
        }
    }

    private const val TAG = "LogosCore"
}
