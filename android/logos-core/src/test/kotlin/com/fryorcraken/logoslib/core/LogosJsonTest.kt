package com.fryorcraken.logoslib.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.math.BigInteger

class LogosJsonTest {

    @Test
    fun `array encodes primitives`() {
        assertEquals("[]", LogosJson.array())
        assertEquals("[\"tag\",3,true,null,1.5]", LogosJson.array("tag", 3, true, null, 1.5))
        assertEquals("[9223372036854775807]", LogosJson.array(Long.MAX_VALUE))
    }

    @Test
    fun `array nests lists maps and raw json`() {
        assertEquals(
            "[[1,2],{\"k\":\"v\",\"n\":null},{\"x\":1}]",
            LogosJson.array(listOf(1, 2), linkedMapOf("k" to "v", "n" to null), LogosJson.Raw("{\"x\":1}")),
        )
    }

    @Test
    fun `quote escapes control characters and quotes`() {
        assertEquals("\"a\\\"b\\\\c\\n\\t\\u0001\"", LogosJson.quote("a\"b\\c\n\t\u0001"))
        // Non-ASCII passes through (the JNI layer converts UTF-16 <-> UTF-8).
        assertEquals("\"hé 😀\"", LogosJson.quote("hé 😀"))
    }

    @Test
    fun `non finite doubles are rejected`() {
        assertThrows(IllegalArgumentException::class.java) { LogosJson.array(Double.NaN) }
    }

    @Test
    fun `parse handles every value kind`() {
        val v = LogosJson.parse("""{"s":"xé\n","i":-12,"big":18446744073709551615,"d":2.5e1,"b":false,"n":null,"a":[1,"2"]}""")
        val m = v as Map<*, *>
        assertEquals("xé\n", m["s"])
        assertEquals(-12L, m["i"])
        assertEquals(BigInteger("18446744073709551615"), m["big"])
        assertEquals(25.0, m["d"])
        assertEquals(false, m["b"])
        assertNull(m["n"])
        assertEquals(listOf(1L, "2"), m["a"])
    }

    @Test
    fun `parse rejects malformed input`() {
        for (bad in listOf("", "[1,]", "{\"a\" 1}", "tru", "\"unterminated", "[1] x", "01x")) {
            assertThrows("should reject: $bad", IllegalArgumentException::class.java) { LogosJson.parse(bad) }
        }
    }

    @Test
    fun `stringOrNull unwraps json strings only`() {
        assertEquals("pong", LogosJson.stringOrNull("\"pong\""))
        assertEquals("", LogosJson.stringOrNull("\"\""))
        assertNull(LogosJson.stringOrNull("42"))
        assertNull(LogosJson.stringOrNull("not json"))
    }

    @Test
    fun `splitArray keeps elements encoded`() {
        assertEquals(emptyList<String>(), LogosJson.splitArray(" [ ] "))
        assertEquals(
            listOf("\"a,b\"", "1", "{\"x\":[2,\"]\"]}", "null"),
            LogosJson.splitArray("[\"a,b\", 1,{\"x\":[2,\"]\"]},null]"),
        )
        assertThrows(IllegalArgumentException::class.java) { LogosJson.splitArray("{\"not\":\"array\"}") }
    }

    @Test
    fun `event args decode string payloads`() {
        val ev = LogosEvent("hello_module", "hello", "[\"tag-1\",7]")
        assertEquals(listOf("\"tag-1\"", "7"), ev.args)
        assertEquals("tag-1", ev.argAsString(0))
        assertEquals("7", ev.argAsString(1))
        assertNull(ev.argAsString(2))
    }

    @Test
    fun `call errors parse the canonical error object`() {
        val e = LogosCallException.fromErrorJson(
            "hello_module", "ping",
            "{\"code\":\"timeout\",\"message\":\"timed out after 1000ms\",\"origin\":\"hello_module\"}",
        )
        assertEquals("timeout", e.code)
        assertEquals("timed out after 1000ms", e.detail)
        assertEquals("hello_module", e.origin)

        val raw = LogosCallException.fromErrorJson("m", "x", "garbage")
        assertEquals("unknown", raw.code)
        assertEquals("garbage", raw.detail)
    }
}
