package com.fryorcraken.logoslib.core.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class RuntimeEnvTest {

    private val appCache = "/data/user/0/com.fryorcraken.logoslib.demo/cache" // 48 bytes

    @Test
    fun `socket path matches liblogos naming`() {
        // $TMPDIR/logos_<module>_<12-char instance id>
        val expected = "$appCache/logos_capability_module_abcdefabcdef".length
        assertEquals(expected, SocketPathBudget.socketPathBytes(appCache, "capability_module"))
        assertEquals(SocketPathBudget.socketPathBytes(appCache, "m"), SocketPathBudget.socketPathBytes("$appCache/", "m"))
    }

    @Test
    fun `the app cache dir leaves room for long module names`() {
        assertTrue(SocketPathBudget.fits(appCache, "capability_module"))
        assertTrue(SocketPathBudget.fits(appCache, "blockchain_module"))
        // 107 usable bytes - 48 (dir) - 1 ('/') - 6 ("logos_") - 1 ('_') - 12 (id) = 39
        assertEquals(39, SocketPathBudget.maxModuleNameBytes(appCache))
        assertTrue(SocketPathBudget.fits(appCache, "m".repeat(39)))
        assertFalse(SocketPathBudget.fits(appCache, "m".repeat(40)))
    }

    @Test
    fun `an 82 character TMPDIR is rejected for capability_module`() {
        // investigation.md section 4: this length made capability_module fail to listen.
        val longTmp = "/" + "d".repeat(81)
        assertEquals(82, longTmp.length)
        assertFalse(SocketPathBudget.fits(longTmp, "capability_module"))
        val e = assertThrows(IllegalStateException::class.java) {
            SocketPathBudget.require(longTmp, listOf("hello_module", "capability_module"))
        }
        assertTrue(e.message!!, e.message!!.contains("'capability_module' (119 bytes)"))
        assertTrue(e.message!!, e.message!!.contains("'hello_module' (114 bytes)"))
        // The app's real cacheDir passes.
        SocketPathBudget.require(appCache, listOf("hello_module", "capability_module"))
    }

    @Test
    fun `budget counts utf-8 bytes`() {
        val nonAscii = "é".repeat(20) // 40 bytes
        assertFalse(SocketPathBudget.fits(appCache, nonAscii))
    }

    @Test
    fun `abi comes from the extracted native library dir`() {
        assertEquals("x86_64", Abi.fromNativeLibraryDir("/data/app/~~x==/com.fryorcraken.logoslib.demo-y==/lib/x86_64"))
        assertEquals("arm64-v8a", Abi.fromNativeLibraryDir("/data/app/pkg/lib/arm64"))
        assertEquals("armeabi-v7a", Abi.fromNativeLibraryDir("/data/app/pkg/lib/arm"))
        assertNull(Abi.fromNativeLibraryDir("/data/app/pkg/lib/mips"))
    }

    @Test
    fun `environment points liblogos at the app dirs`() {
        val layout = Layout(
            abi = "x86_64",
            nativeLibDir = File("/data/app/pkg/lib/x86_64"),
            tmpDir = File(appCache),
            homeDir = File("/data/user/0/pkg/files"),
            modulesDir = File("/data/user/0/pkg/files/modules"),
            persistDir = File("/data/user/0/pkg/files/persist"),
            workDir = File("/data/user/0/pkg/files/work"),
        )
        val env = RuntimeEnv.variables(layout)
        assertEquals(appCache, env["TMPDIR"])
        assertEquals("/data/user/0/pkg/files", env["HOME"])
        assertEquals("/data/app/pkg/lib/x86_64", env["LD_LIBRARY_PATH"])
        assertEquals("/data/app/pkg/lib/x86_64/liblogos_host_qt.so", env["LOGOS_HOST_PATH"])
    }

    @Test
    fun `required libraries use qt abi suffixes`() {
        val libs = NativeLibs.requiredFiles("arm64-v8a")
        assertTrue("libQt6Core_arm64-v8a.so" in libs)
        assertTrue("liblogos_jni.so" in libs)
        assertTrue("liblogos_host_qt.so" in libs)
        // QtCore-dependent libraries must never be System.loadLibrary'd (JNI_OnLoad lookup).
        assertTrue(NativeLibs.PRELOAD.none { it.startsWith("Qt6") || it.startsWith("logos") })
    }

    @Test
    fun `asset version key changes with stamp app update and module set`() {
        val base = ModuleAssets.versionKey("abc", 1, 1000, "x86_64", listOf("hello_module", "capability_module"))
        assertEquals(base, ModuleAssets.versionKey("abc\n", 1, 1000, "x86_64", listOf("capability_module", "hello_module")))
        assertNotEquals(base, ModuleAssets.versionKey("abd", 1, 1000, "x86_64", listOf("hello_module", "capability_module")))
        assertNotEquals(base, ModuleAssets.versionKey("abc", 1, 2000, "x86_64", listOf("hello_module", "capability_module")))
        assertNotEquals(base, ModuleAssets.versionKey("abc", 1, 1000, "x86_64", listOf("capability_module")))
    }
}
