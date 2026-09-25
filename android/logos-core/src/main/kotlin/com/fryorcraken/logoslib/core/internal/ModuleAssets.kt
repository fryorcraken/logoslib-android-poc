package com.fryorcraken.logoslib.core.internal

import android.content.Context
import android.content.res.AssetManager
import android.util.Log
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException

/**
 * Extracts the module directories staged in `assets/modules/<abi>/<module>/...`
 * (manifest.json, plugin .so, private deps; written by scripts/android/stage.sh) to
 * `filesDir/modules/<module>/...`, the directory handed to logos_core_add_modules_dir().
 *
 * Versioned: stage.sh writes `assets/modules/<abi>/modules.stamp` (a content hash; not a
 * dot-file, which aapt would silently leave out of the APK). The extracted
 * tree records the stamp plus the APK's versionCode/lastUpdateTime in
 * [VERSION_FILE]; any difference (app update, re-staged modules, different module subset)
 * re-extracts into a temporary directory that then replaces the old tree. Module
 * directories are made read-only: nothing at run time should modify a plugin.
 */
internal object ModuleAssets {
    private const val TAG = "LogosCore"
    const val ROOT = "modules"
    const val STAMP = "modules.stamp"
    const val VERSION_FILE = ".logos-assets-version"

    data class Result(val modules: List<String>, val extracted: Boolean, val version: String)

    /** Names of the module directories packaged for [abi] (empty if none were staged). */
    fun packagedModules(assets: AssetManager, abi: String): List<String> =
        (assets.list("$ROOT/$abi") ?: emptyArray()).filter { !it.startsWith(".") && it != STAMP }.sorted()

    /** The version key the extracted tree is compared against. Pure; unit-tested. */
    fun versionKey(stamp: String, versionCode: Long, lastUpdateTime: Long, abi: String, modules: List<String>): String =
        "v1|abi=$abi|stamp=${stamp.trim()}|app=$versionCode@$lastUpdateTime|modules=${modules.sorted().joinToString(",")}"

    fun extract(context: Context, abi: String, dest: File, only: List<String>, readOnly: Boolean): Result {
        val assets = context.assets
        val packaged = packagedModules(assets, abi)
        val missing = only.filterNot { it in packaged }
        require(missing.isEmpty()) { "modules not packaged in assets/$ROOT/$abi: $missing (packaged: $packaged)" }
        val modules = if (only.isEmpty()) packaged else only.distinct().sorted()

        val stamp = readAssetText(assets, "$ROOT/$abi/$STAMP") ?: ""
        val pkg = context.packageManager.getPackageInfo(context.packageName, 0)
        val version = versionKey(stamp, pkg.longVersionCode, pkg.lastUpdateTime, abi, modules)

        val current = runCatching { File(dest, VERSION_FILE).readText() }.getOrNull()
        if (current == version && modules.all { File(dest, it).isDirectory }) {
            return Result(modules, extracted = false, version = version)
        }

        if (modules.isEmpty()) Log.w(TAG, "no modules packaged in assets/$ROOT/$abi -- liblogos will know none")
        val tmp = File(dest.parentFile, dest.name + ".tmp")
        deleteTree(tmp)
        check(tmp.mkdirs()) { "cannot create $tmp" }
        for (m in modules) copyTree(assets, "$ROOT/$abi/$m", File(tmp, m))
        File(tmp, VERSION_FILE).writeText(version)
        if (readOnly) modules.forEach { setTreeWritable(File(tmp, it), false) }

        deleteTree(dest)
        if (!tmp.renameTo(dest)) throw IOException("cannot rename $tmp to $dest")
        Log.i(TAG, "extracted modules $modules to $dest ($version)")
        return Result(modules, extracted = true, version = version)
    }

    private fun readAssetText(assets: AssetManager, path: String): String? =
        try {
            assets.open(path).use { it.readBytes().toString(Charsets.UTF_8) }
        } catch (_: FileNotFoundException) {
            null
        } catch (_: IOException) {
            null
        }

    /** AssetManager has no "is directory": a path that lists children is a directory. */
    private fun copyTree(assets: AssetManager, from: String, to: File) {
        val children = assets.list(from) ?: emptyArray()
        if (children.isEmpty()) {
            try {
                assets.open(from).use { input -> to.outputStream().use { input.copyTo(it) } }
                return
            } catch (_: FileNotFoundException) {
                to.mkdirs() // an empty directory
                return
            }
        }
        check(to.isDirectory || to.mkdirs()) { "cannot create $to" }
        for (c in children) copyTree(assets, "$from/$c", File(to, c))
    }

    private fun setTreeWritable(root: File, writable: Boolean) {
        // Children first when locking, parents first when unlocking.
        if (writable) root.setWritable(true, true)
        root.listFiles()?.forEach { setTreeWritable(it, writable) }
        if (!writable) root.setWritable(false, false)
    }

    fun deleteTree(root: File) {
        if (!root.exists()) return
        setTreeWritable(root, true)
        if (!root.deleteRecursively()) throw IOException("cannot delete $root")
    }
}
