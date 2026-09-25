package com.fryorcraken.logoslib.core.internal

import com.fryorcraken.logoslib.core.ModuleStats
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ModuleStatsTest {

    @Test
    fun `module stats json is parsed and malformed entries are skipped`() {
        val json = """[{"name":"blockchain_module","pid":4999,"cpu_percent":5.5,"cpu_time_seconds":1.25,"memory_mb":155.8},""" +
            """{"pid":1},{"name":"bc_probe","pid":5001}]"""
        val stats = ModuleStats.parseList(json)
        assertEquals(2, stats.size)
        assertEquals(ModuleStats("blockchain_module", 4999, 5.5, 1.25, 155.8), stats[0])
        assertEquals("bc_probe", stats[1].name)
        assertEquals(0.0, stats[1].memoryMb, 0.0)
        assertTrue(ModuleStats.parseList(null).isEmpty())
        assertTrue(ModuleStats.parseList("not json").isEmpty())
    }

    @Test
    fun `cpu ticks are utime plus stime, fields 14 and 15`() {
        // pid (comm) state ppid pgrp session tty tpgid flags minflt cminflt majflt cmajflt utime stime cutime cstime ...
        val stat = "4999 (liblogos_host_q) S 4918 4918 0 0 -1 4194624 51234 0 12 0 2500 425 7 9 20 0 15 0 1234 11265700 39840"
        assertEquals(2925L, ProcStat.cpuTicks(stat))
    }

    @Test
    fun `comm with spaces and parentheses does not shift the fields`() {
        val stat = "77 (a b) c) R 1 1 0 0 -1 0 0 0 0 0 30 12 0 0 20 0 1 0 5 100 10"
        assertEquals(42L, ProcStat.cpuTicks(stat))
        assertNull(ProcStat.cpuTicks("garbage"))
        assertNull(ProcStat.cpuTicks("1 (x) S 1 2"))
    }
}
