package org.vrpassthroughplayer.plugin

import java.net.URI

/** Escape Unicode without composing distinct filesystem names into the same URI. */
internal fun URI.mediaAsciiString(): String {
    val value = toString()
    if (value.all { it.code < 128 }) return value
    val hex = "0123456789ABCDEF"
    return buildString(value.length) {
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val code = byte.toInt() and 255
            if (code < 128) append(code.toChar())
            else append('%').append(hex[code shr 4]).append(hex[code and 15])
        }
    }
}
