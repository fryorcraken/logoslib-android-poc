package com.fryorcraken.logoslib.core.internal

import android.util.Log
import java.io.File

/**
 * Loads the native runtime into the app process.
 *
 * Only libraries that do NOT depend on QtCore are loaded explicitly: System.loadLibrary()
 * makes ART look up `JNI_OnLoad` with dlsym(handle), and bionic resolves that through the
 * library's DT_NEEDED tree. For libQt6Core_<abi>.so itself, and for anything that links it
 * (QtNetwork, QtRemoteObjects, liblogos_core, liblogos_protocol, ...), that finds QtCore's
 * JNI_OnLoad, which returns JNI_ERR without Qt6Android.jar -> UnsatisfiedLinkError
 * (qt-jvmless run R4). liblogos_jni.so defines its own JNI_OnLoad (which primes QtCore with
 * the real JavaVM and ignores its JNI_ERR), and loading it pulls in the whole Qt/liblogos
 * closure through DT_NEEDED from the app's linker namespace (nativeLibraryDir).
 *
 * Effective order: c++_shared -> OpenSSL (if packaged; QtNetwork dlopen()s it by name at run
 * time, so preloading only surfaces a broken copy early) -> logos_jni (+ its DT_NEEDED:
 * Qt6Core_<abi>, Qt6Network_<abi>, Qt6RemoteObjects_<abi>, liblogos_protocol, liblogos_core, ...).
 */
internal object NativeLibs {
    private const val TAG = "LogosCore"

    /** Loaded explicitly, in order, when present in nativeLibraryDir. No Qt dependency. */
    val PRELOAD: List<String> = listOf(
        "c++_shared",
        // OpenSSL: the names depend on how build-deps.sh names it for QtNetwork's dlopen.
        "crypto_3", "ssl_3", "crypto", "ssl",
    )

    const val JNI_LIB = "logos_jni"

    /** Libraries every packaged runtime must contain (checked before loading, for a clear error). */
    fun requiredFiles(abi: String): List<String> = listOf(
        "libc++_shared.so",
        "libQt6Core_$abi.so",
        "libQt6Network_$abi.so",
        "libQt6RemoteObjects_$abi.so",
        "liblogos_core.so",
        "liblogos_protocol.so",
        "lib$JNI_LIB.so",
        Layout.HOST_LIB,
    )

    @Volatile
    private var loaded = false

    /** Returns the list of libraries loaded explicitly. Idempotent. */
    @Synchronized
    fun load(layout: Layout): List<String> {
        if (loaded) return emptyList()
        val missing = requiredFiles(layout.abi).filterNot { File(layout.nativeLibDir, it).isFile }
        if (missing.isNotEmpty()) {
            throw IllegalStateException(
                "native runtime not packaged for ${layout.abi}: missing $missing in ${layout.nativeLibDir} " +
                    "(run scripts/android/build-jni.sh and scripts/android/stage.sh, then rebuild the APK)",
            )
        }
        val done = ArrayList<String>()
        for (name in PRELOAD) {
            if (File(layout.nativeLibDir, "lib$name.so").isFile) {
                System.loadLibrary(name)
                done += name
            }
        }
        System.loadLibrary(JNI_LIB)
        done += JNI_LIB
        loaded = true
        Log.i(TAG, "loaded native libraries: $done")
        return done
    }
}
