package com.fryorcraken.logoslib.core.internal

import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import com.fryorcraken.logoslib.core.ModuleStats
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * CPU time of a module host from `/proc/<pid>/stat` (same uid, so readable).
 *
 * Why not liblogos' own figure: process-stats 6e0aade skips 14 whitespace tokens of
 * `/proc/<pid>/stat` and then reads "utime" and "stime", which are therefore fields 15 and
 * 16 (stime and cutime): it reports kernel time only. On the emulator that read 4-9 % for a
 * syncing node that `top` showed at 105-121 %. See patches/process-stats/ (proposal).
 */
internal object ProcStat {
    /** utime + stime in clock ticks (proc(5) fields 14 and 15), parsed after "(comm)". */
    fun cpuTicks(stat: String): Long? {
        val rest = stat.substringAfterLast(')', "").trim()
        if (rest.isEmpty()) return null
        val f = rest.split(' ').filter { it.isNotEmpty() }
        // rest starts at field 3 (state): field n is f[n - 3].
        val utime = f.getOrNull(14 - 3)?.toLongOrNull() ?: return null
        val stime = f.getOrNull(15 - 3)?.toLongOrNull() ?: return null
        return utime + stime
    }

    private val ticksPerSecond: Long by lazy {
        runCatching { Os.sysconf(OsConstants._SC_CLK_TCK) }.getOrDefault(100L).takeIf { it > 0 } ?: 100L
    }

    fun cpuSeconds(pid: Long): Double? {
        if (pid <= 0) return null
        val text = runCatching { File("/proc/$pid/stat").readText() }.getOrNull() ?: return null
        return cpuTicks(text)?.let { it.toDouble() / ticksPerSecond }
    }

    /** Previous (cpu seconds, elapsedRealtime ms) per pid, for [corrected]'s cpu_percent. */
    private val samples = ConcurrentHashMap<Long, Pair<Double, Long>>()

    /**
     * [s] with cpuTimeSeconds read from /proc and cpuPercent over the interval since the
     * previous call for that pid (0 on the first). Unchanged if /proc cannot be read.
     */
    fun corrected(s: ModuleStats): ModuleStats {
        val cpu = cpuSeconds(s.pid) ?: return s
        val now = SystemClock.elapsedRealtime()
        val prev = samples.put(s.pid, cpu to now)
        val pct = if (prev != null && now > prev.second) (cpu - prev.first) * 100_000.0 / (now - prev.second) else 0.0
        return s.copy(cpuTimeSeconds = cpu, cpuPercent = pct)
    }
}
