package com.fryorcraken.logoslib.core.internal

import android.content.Context
import android.os.Build
import android.system.Os
import java.io.File

/**
 * The QtRO socket budget. Every module host listens on
 * `local:logos_<module>_<instanceId>` (logos-protocol logos_instance.h: the instance id is
 * 12 characters), which QLocalServer turns into `$TMPDIR/logos_<module>_<id>`. That path
 * must fit `sockaddr_un.sun_path` (108 bytes including the terminating NUL); with an
 * 82-character TMPDIR capability_module failed to listen and crashed (investigation.md §4).
 */
internal object SocketPathBudget {
    const val SUN_PATH_BYTES = 108
    const val INSTANCE_ID_CHARS = 12
    private const val PREFIX = "logos_"

    /** Byte length of the socket path liblogos will bind for [module] under [tmpDir]. */
    fun socketPathBytes(tmpDir: String, module: String): Int =
        (tmpDir.trimEnd('/') + "/" + PREFIX + module + "_" + "x".repeat(INSTANCE_ID_CHARS))
            .toByteArray(Charsets.UTF_8).size

    /** Longest module name that still fits under [tmpDir]. */
    fun maxModuleNameBytes(tmpDir: String): Int =
        SUN_PATH_BYTES - 1 - socketPathBytes(tmpDir, "")

    fun fits(tmpDir: String, module: String): Boolean =
        socketPathBytes(tmpDir, module) <= SUN_PATH_BYTES - 1

    /** Throws [IllegalStateException] naming every module whose socket path would not fit. */
    fun require(tmpDir: String, modules: Collection<String>) {
        val tooLong = modules.filterNot { fits(tmpDir, it) }
        check(tooLong.isEmpty()) {
            "TMPDIR '$tmpDir' is too long for module(s) " +
                tooLong.joinToString { "'$it' (${socketPathBytes(tmpDir, it)} bytes)" } +
                ": sun_path allows ${SUN_PATH_BYTES - 1} bytes; module names up to " +
                "${maxModuleNameBytes(tmpDir)} bytes fit under this TMPDIR"
        }
    }
}

/** Android ABI names as used by jniLibs/<abi>, Qt's lib suffix and assets/modules/<abi>. */
internal object Abi {
    /**
     * Maps the last segment of ApplicationInfo.nativeLibraryDir (".../lib/x86_64",
     * ".../lib/arm64") to the Android ABI name ("x86_64", "arm64-v8a"). That directory is
     * what the package manager actually extracted, so it beats Build.SUPPORTED_ABIS.
     */
    fun fromNativeLibraryDir(path: String): String? = when (File(path).name) {
        "x86_64" -> "x86_64"
        "arm64" -> "arm64-v8a"
        "x86" -> "x86"
        "arm" -> "armeabi-v7a"
        else -> null
    }

    fun current(nativeLibraryDir: String): String =
        fromNativeLibraryDir(nativeLibraryDir) ?: Build.SUPPORTED_ABIS.first()
}

/** Where everything lives on the device. */
internal data class Layout(
    val abi: String,
    val nativeLibDir: File,
    val tmpDir: File,
    val homeDir: File,
    val modulesDir: File,
    val persistDir: File,
) {
    /** liblogos' module host executable, shipped as a "library" so it gets extracted. */
    val hostExecutable: File get() = File(nativeLibDir, HOST_LIB)

    companion object {
        const val HOST_LIB = "liblogos_host_qt.so"

        fun from(context: Context): Layout {
            val nativeLibDir = File(context.applicationInfo.nativeLibraryDir)
            val files = context.filesDir
            return Layout(
                abi = Abi.current(nativeLibDir.path),
                nativeLibDir = nativeLibDir,
                // cacheDir: short (/data/user/0/<pkg>/cache) and the parent<->child QtRO
                // socket there needs no SELinux change (qt-jvmless X2).
                tmpDir = context.cacheDir,
                homeDir = files,
                modulesDir = File(files, "modules"),
                persistDir = File(files, "persist"),
            )
        }
    }
}

/** Process environment liblogos and its children read (investigation.md §6, "Environment"). */
internal object RuntimeEnv {
    fun variables(layout: Layout): Map<String, String> = linkedMapOf(
        // QDir::tempPath() -> QtRO socket directory (see SocketPathBudget).
        "TMPDIR" to layout.tmpDir.path,
        "HOME" to layout.homeDir.path,
        // Children (liblogos_host_qt.so) are plain executables in the default linker
        // namespace: they find Qt, liblogos_* and friends through LD_LIBRARY_PATH.
        "LD_LIBRARY_PATH" to layout.nativeLibDir.path,
        // liblogos' host discovery: the executable is not next to app_process64.
        "LOGOS_HOST_PATH" to layout.hostExecutable.path,
    )

    /** Applies [variables] with Os.setenv; must run before liblogos_jni.so is loaded. */
    fun apply(layout: Layout): Map<String, String> {
        val vars = variables(layout)
        for ((k, v) in vars) Os.setenv(k, v, true)
        return vars
    }
}
