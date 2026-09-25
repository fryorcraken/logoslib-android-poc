package com.fryorcraken.logoslib.core

/**
 * One module host process, from `logos_core_get_module_stats()` (liblogos' process-stats reads
 * `/proc/<pid>`). [cpuPercent] is averaged since the previous stats call for that process, so
 * the first sample of a process reads 0; 100 means one full core.
 */
public data class ModuleStats(
    val name: String,
    val pid: Long,
    val cpuPercent: Double,
    val cpuTimeSeconds: Double,
    val memoryMb: Double,
) {
    public companion object {
        /** Parses the JSON array `logos_core_get_module_stats()` returns; malformed entries are skipped. */
        public fun parseList(json: String?): List<ModuleStats> {
            if (json.isNullOrBlank()) return emptyList()
            val list = runCatching { LogosJson.parse(json) }.getOrNull() as? List<*> ?: return emptyList()
            return list.mapNotNull { e ->
                val m = e as? Map<*, *> ?: return@mapNotNull null
                val name = m["name"] as? String ?: return@mapNotNull null
                ModuleStats(
                    name = name,
                    pid = (m["pid"] as? Number)?.toLong() ?: -1,
                    cpuPercent = (m["cpu_percent"] as? Number)?.toDouble() ?: 0.0,
                    cpuTimeSeconds = (m["cpu_time_seconds"] as? Number)?.toDouble() ?: 0.0,
                    memoryMb = (m["memory_mb"] as? Number)?.toDouble() ?: 0.0,
                )
            }
        }
    }
}

/**
 * A module that stopped being loaded without [LogosCore.unloadModule]: its host process
 * exited or crashed. liblogos notices the child's termination and drops the module from
 * `logos_core_get_loaded_modules()`; [LogosCore] watches that list (every
 * [LogosConfig.moduleWatchInterval]) and reports the difference here.
 *
 * @property lastPid the host's pid as last seen in [LogosCore.moduleStats], if it was sampled.
 * @property uptimeMillis how long the module had been loaded, as far as [LogosCore] knows.
 */
public data class ModuleExit(
    val module: String,
    val lastPid: Long?,
    val detectedAtMillis: Long,
    val uptimeMillis: Long?,
    val reason: String,
)
