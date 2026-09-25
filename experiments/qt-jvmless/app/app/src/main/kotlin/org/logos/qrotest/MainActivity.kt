package org.logos.qrotest

import android.app.Activity
import android.os.Bundle
import android.system.Os
import android.util.Log
import android.widget.ScrollView
import android.widget.TextView
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * qt-jvmless X2: exec a Qt helper executable (libqro_server.so) from nativeLibraryDir
 * and talk to it over QtRO from a JNI client that owns a QCoreApplication on a
 * dedicated Java thread.
 *
 * Intent extras (all optional):
 *   jvmMode        client JNI mode: none | realvm | appversion | shim  (default per flavor)
 *   serverJvmMode  helper --jvm-mode: none | appversion | shim           (default shim)
 *   url            QtRO url, local:qro_t or localabstract:qro_t         (default local:qro_t)
 *   jniLib         qrotest_jni | qrotest_jni_noonload                    (default qrotest_jni)
 *   loadQtCore     explicitly System.loadLibrary("Qt6Core_x86_64") first (default = flavor has jar)
 *   spawn          java (ProcessBuilder, explicit env) | native (posix_spawn from JNI, inherited environ)
 */
class MainActivity : Activity() {
    private lateinit var tv: TextView
    private val sb = StringBuilder()
    @Volatile private var server: Process? = null

    private fun log(msg: String) {
        Log.i(TAG, msg)
        synchronized(sb) { sb.append(msg).append('\n') }
        runOnUiThread { tv.text = synchronized(sb) { sb.toString() } }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before anything else touches Qt: QDir::tempPath() reads TMPDIR.
        Os.setenv("TMPDIR", cacheDir.absolutePath, true)
        super.onCreate(savedInstanceState)
        tv = TextView(this).apply { setPadding(24, 48, 24, 24); textSize = 12f }
        setContentView(ScrollView(this).apply { addView(tv) })

        val jvmMode = intent.getStringExtra("jvmMode") ?: BuildConfig.DEFAULT_JVM_MODE
        val serverJvmMode = intent.getStringExtra("serverJvmMode") ?: "shim"
        val url = intent.getStringExtra("url") ?: "local:qro_t"
        val jniLib = intent.getStringExtra("jniLib") ?: "qrotest_jni"
        val loadQtCore = if (intent.hasExtra("loadQtCore")) intent.getBooleanExtra("loadQtCore", false) else BuildConfig.QT_JAR
        val spawn = intent.getStringExtra("spawn") ?: "java"

        Thread({ runTest(jvmMode, serverJvmMode, url, jniLib, loadQtCore, spawn) }, "logos-qt").start()
    }

    private fun runTest(jvmMode: String, serverJvmMode: String, url: String, jniLib: String, loadQtCore: Boolean, spawn: String) {
        val nld = applicationInfo.nativeLibraryDir
        log("CONFIG flavor=${BuildConfig.FLAVOR} qtJar=${BuildConfig.QT_JAR} jvmMode=$jvmMode serverJvmMode=$serverJvmMode url=$url jniLib=$jniLib loadQtCore=$loadQtCore spawn=$spawn")
        log("pid=${android.os.Process.myPid()} uid=${android.os.Process.myUid()} TMPDIR=${Os.getenv("TMPDIR")}")
        log("nativeLibraryDir=$nld")
        val exe = File(nld, "libqro_server.so")
        log("nativeLibraryDir contents: ${File(nld).list()?.sorted()}")
        log("libqro_server.so exists=${exe.exists()} canExecute=${exe.canExecute()} size=${exe.length()}")
        try {
            val st = Os.stat(exe.absolutePath)
            log("libqro_server.so mode=${Integer.toOctalString(st.st_mode)}")
        } catch (e: Exception) {
            log("stat failed: $e")
        }

        val helperArgs = arrayOf(
            exe.absolutePath,
            "--jvm-mode=$serverJvmMode",
            "--url=$url",
            "--plugin=$nld/libechoplugin.so",
            "--exit-after-ms=120000",
        )
        if (spawn == "native") {
            // liblogos-like: native posix_spawn, environment inherited from the app process.
            if (!loadLibs(jniLib, loadQtCore)) return
            Os.setenv("LD_LIBRARY_PATH", nld, true)
            val pid = NativeBridge.spawnHelper(helperArgs)
            log("HELPER posix_spawn pid=$pid")
            val sock = File(cacheDir, "qro_t")
            for (i in 0 until 50) {
                if (sock.exists() || url.startsWith("localabstract")) break
                Thread.sleep(100)
            }
            if (url.startsWith("localabstract")) Thread.sleep(1500)
            log("helper socket exists=${sock.exists()}")
        } else {
            startJavaHelper(helperArgs, nld)
            if (!loadLibs(jniLib, loadQtCore)) return
        }

        // 3. JNI client (QCoreApplication on this thread)
        val result = try {
            NativeBridge.runClient(url, 10000, jvmMode)
        } catch (t: Throwable) {
            "FAIL exception $t"
        }
        log("RESULT: $result")
    }

    private fun loadLibs(jniLib: String, loadQtCore: Boolean): Boolean {
        try {
            if (loadQtCore) {
                System.loadLibrary("c++_shared")
                System.loadLibrary("Qt6Core_x86_64")
                log("System.loadLibrary(Qt6Core_x86_64) OK (QtCore JNI_OnLoad ran)")
            }
            System.loadLibrary(jniLib)
            log("System.loadLibrary($jniLib) OK")
            return true
        } catch (t: Throwable) {
            log("LOADLIBRARY FAILED: $t")
            log("RESULT: FAIL loadLibrary")
            return false
        }
    }

    private fun startJavaHelper(helperArgs: Array<String>, nld: String) {
        // 1. exec the helper via java.lang.ProcessBuilder
        val ready = CountDownLatch(1)
        try {
            val pb = ProcessBuilder(*helperArgs)
            pb.environment()["LD_LIBRARY_PATH"] = nld
            pb.environment()["TMPDIR"] = cacheDir.absolutePath
            pb.redirectErrorStream(true)
            val p = pb.start()
            server = p
            log("HELPER started: $p")
            Thread({
                p.inputStream.bufferedReader().forEachLine { line ->
                    Log.i(CHILD_TAG, line)
                    if (line.contains("PLUGIN") || line.contains("setRegistryUrl") || line.contains("READY") ||
                        line.contains("FAIL") || line.contains("jvm-mode") || line.contains("libart") ||
                        line.contains("tempPath") || line.contains("ppid")) log("child> $line")
                    if (line.contains("server: READY")) ready.countDown()
                }
                val rc = try { p.waitFor() } catch (e: InterruptedException) { -1 }
                log("HELPER exited rc=$rc")
                ready.countDown()
            }, "helper-stdout").start()
        } catch (e: Exception) {
            log("HELPER EXEC FAILED: $e")
        }
        val gotReady = ready.await(15, TimeUnit.SECONDS)
        log("helper READY seen=$gotReady")
    }

    override fun onDestroy() {
        server?.destroy()
        super.onDestroy()
    }

    companion object {
        const val TAG = "qrotest"
        const val CHILD_TAG = "qrotest-child"
    }
}
