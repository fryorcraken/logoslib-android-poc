package com.fryorcraken.logoslib.core

import java.math.BigDecimal
import java.math.BigInteger

/**
 * Minimal JSON helpers for the liblogos call boundary.
 *
 * The `lp_*` C ABI is JSON-in-strings: method arguments are a JSON **array**, results are a
 * JSON **value**, event payloads are a JSON **array** (logos_protocol.h). These helpers
 * build argument arrays and read results without pulling in a JSON library, and they are
 * pure Kotlin so they run in JVM unit tests (android.jar's `org.json` is a stub there).
 *
 * Parsed values map to: `null`, [Boolean], [String], [Long] (integers that fit),
 * [BigInteger] (larger integers, e.g. uint64), [Double] (fractions/exponents),
 * `List<Any?>` and `Map<String, Any?>` (insertion-ordered).
 */
public object LogosJson {

    /** Wraps pre-encoded JSON so [array]/[stringify] embed it verbatim. */
    public class Raw(public val json: String) {
        override fun toString(): String = json
    }

    /** Encodes [s] as a JSON string literal (with quotes). */
    public fun quote(s: String): String {
        val sb = StringBuilder(s.length + 2)
        sb.append('"')
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                '\b' -> sb.append("\\b")
                '\u000C' -> sb.append("\\f")
                else -> if (c < ' ') sb.append(String.format("\\u%04x", c.code)) else sb.append(c)
            }
        }
        sb.append('"')
        return sb.toString()
    }

    /**
     * Builds a JSON argument array, e.g. `array("tag", 3, true)` -> `["tag",3,true]`.
     * Elements may be null, String, Boolean, any [Number], [Raw], List/Array or Map.
     */
    public fun array(vararg values: Any?): String = stringify(values.toList())

    /** Encodes a Kotlin value (see [array] for the supported types) as JSON. */
    public fun stringify(value: Any?): String = StringBuilder().also { write(it, value) }.toString()

    private fun write(sb: StringBuilder, v: Any?) {
        when (v) {
            null -> sb.append("null")
            is Raw -> sb.append(v.json)
            is String -> sb.append(quote(v))
            is Char -> sb.append(quote(v.toString()))
            is Boolean -> sb.append(if (v) "true" else "false")
            is Double -> {
                require(v.isFinite()) { "JSON cannot encode $v" }
                sb.append(v.toString()) // "3.0", "1.0E10": both valid JSON numbers
            }
            is Float -> write(sb, v.toDouble())
            is BigDecimal -> sb.append(v.toPlainString())
            is Number -> sb.append(v.toString())
            is Map<*, *> -> {
                sb.append('{')
                var first = true
                for ((k, value) in v) {
                    if (!first) sb.append(',')
                    first = false
                    sb.append(quote(k.toString())).append(':')
                    write(sb, value)
                }
                sb.append('}')
            }
            is Iterable<*> -> {
                sb.append('[')
                var first = true
                for (e in v) {
                    if (!first) sb.append(',')
                    first = false
                    write(sb, e)
                }
                sb.append(']')
            }
            is Array<*> -> write(sb, v.asList())
            else -> throw IllegalArgumentException("cannot encode ${v::class.java.name} as JSON")
        }
    }

    /** Parses one JSON value. Throws [IllegalArgumentException] on malformed input. */
    public fun parse(json: String): Any? = Parser(json).parseDocument()

    /** The string if [json] is a JSON string literal (e.g. `"\"pong\""` -> `pong`), else null. */
    public fun stringOrNull(json: String): String? =
        runCatching { parse(json) }.getOrNull() as? String

    /**
     * Splits a JSON array into its top-level elements, each still JSON-encoded:
     * `["a",1,{"x":[2]}]` -> [`"a"`, `1`, `{"x":[2]}`]. Used for event payloads.
     */
    public fun splitArray(json: String): List<String> {
        val p = Parser(json)
        p.skipWs()
        p.expect('[')
        val out = ArrayList<String>()
        p.skipWs()
        if (p.peek() == ']') {
            p.pos++
            p.ensureEnd()
            return out
        }
        while (true) {
            p.skipWs()
            val start = p.pos
            p.parseValue()
            out.add(json.substring(start, p.pos))
            p.skipWs()
            when (p.next()) {
                ',' -> continue
                ']' -> break
                else -> p.fail("expected ',' or ']'")
            }
        }
        p.ensureEnd()
        return out
    }

    private class Parser(val s: String) {
        var pos = 0

        fun fail(msg: String): Nothing =
            throw IllegalArgumentException("malformed JSON at offset $pos: $msg")

        fun peek(): Char = if (pos < s.length) s[pos] else '\u0000'
        fun next(): Char = if (pos < s.length) s[pos++] else fail("unexpected end")
        fun expect(c: Char) {
            if (next() != c) {
                pos--
                fail("expected '$c'")
            }
        }

        fun skipWs() {
            while (pos < s.length && (s[pos] == ' ' || s[pos] == '\n' || s[pos] == '\r' || s[pos] == '\t')) pos++
        }

        fun ensureEnd() {
            skipWs()
            if (pos != s.length) fail("trailing characters")
        }

        fun parseDocument(): Any? {
            skipWs()
            val v = parseValue()
            ensureEnd()
            return v
        }

        fun parseValue(): Any? {
            skipWs()
            return when (peek()) {
                '{' -> parseObject()
                '[' -> parseArray()
                '"' -> parseString()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> parseNumber()
            }
        }

        fun literal(word: String, value: Any?): Any? {
            if (!s.startsWith(word, pos)) fail("expected $word")
            pos += word.length
            return value
        }

        fun parseObject(): Map<String, Any?> {
            expect('{')
            val m = LinkedHashMap<String, Any?>()
            skipWs()
            if (peek() == '}') {
                pos++
                return m
            }
            while (true) {
                skipWs()
                if (peek() != '"') fail("expected object key")
                val k = parseString()
                skipWs()
                expect(':')
                m[k] = parseValue()
                skipWs()
                when (next()) {
                    ',' -> continue
                    '}' -> return m
                    else -> {
                        pos--
                        fail("expected ',' or '}'")
                    }
                }
            }
        }

        fun parseArray(): List<Any?> {
            expect('[')
            val l = ArrayList<Any?>()
            skipWs()
            if (peek() == ']') {
                pos++
                return l
            }
            while (true) {
                l.add(parseValue())
                skipWs()
                when (next()) {
                    ',' -> continue
                    ']' -> return l
                    else -> {
                        pos--
                        fail("expected ',' or ']'")
                    }
                }
            }
        }

        fun parseString(): String {
            expect('"')
            val sb = StringBuilder()
            while (true) {
                val c = next()
                when {
                    c == '"' -> return sb.toString()
                    c == '\\' -> when (val e = next()) {
                        '"' -> sb.append('"')
                        '\\' -> sb.append('\\')
                        '/' -> sb.append('/')
                        'b' -> sb.append('\b')
                        'f' -> sb.append('\u000C')
                        'n' -> sb.append('\n')
                        'r' -> sb.append('\r')
                        't' -> sb.append('\t')
                        'u' -> {
                            if (pos + 4 > s.length) fail("short \\u escape")
                            val hex = s.substring(pos, pos + 4)
                            val code = hex.toIntOrNull(16) ?: fail("bad \\u escape '$hex'")
                            sb.append(code.toChar())
                            pos += 4
                        }
                        else -> fail("bad escape '\\$e'")
                    }
                    c < ' ' -> fail("control character in string")
                    else -> sb.append(c)
                }
            }
        }

        fun parseNumber(): Any {
            val start = pos
            if (peek() == '-') pos++
            if (peek() !in '0'..'9') fail("expected a value")
            while (peek() in '0'..'9') pos++
            var integral = true
            if (peek() == '.') {
                integral = false
                pos++
                if (peek() !in '0'..'9') fail("expected digits after '.'")
                while (peek() in '0'..'9') pos++
            }
            if (peek() == 'e' || peek() == 'E') {
                integral = false
                pos++
                if (peek() == '+' || peek() == '-') pos++
                if (peek() !in '0'..'9') fail("expected exponent digits")
                while (peek() in '0'..'9') pos++
            }
            val text = s.substring(start, pos)
            if (!integral) return text.toDouble()
            return text.toLongOrNull() ?: BigInteger(text)
        }
    }
}
