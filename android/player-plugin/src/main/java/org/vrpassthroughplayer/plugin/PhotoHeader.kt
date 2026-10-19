package org.vrpassthroughplayer.plugin

/** Dimensions from at most 1 MiB of a transfer. No pixel decode, IO or Android dependency. */
internal data class PhotoHeader(val width: Int, val height: Int, val orientation: Int = 1, val nativeStereo: Boolean = false) {
    companion object {
        const val MAX_BYTES = 1024 * 1024
        // EXIF 0 means undefined: the pixel order is unchanged, just as when the tag is absent.
        fun normalizedOrientation(value: Int): Int = value.takeIf { it in 1..8 } ?: 1
        fun read(b: ByteArray): PhotoHeader? {
            if (b.size < 30) return null
            if (String(b, 4, 4, Charsets.ISO_8859_1) == "ftyp")
                return runCatching { HeifPhotoInfo.readPrefix(b) }.getOrNull()?.let { PhotoHeader(it.packedWidth, it.height, 1, it.stereo) }
            fun u8(at: Int) = b[at].toInt() and 255
            fun u16(at: Int, little: Boolean = false): Int {
                if (at < 0 || at.toLong() + 2 > b.size) return 0
                return if (little) u8(at) or (u8(at + 1) shl 8) else (u8(at) shl 8) or u8(at + 1)
            }
            fun u32(at: Int, little: Boolean = false): Long {
                if (at < 0 || at.toLong() + 4 > b.size) return 0
                return if (little) u16(at, true).toLong() or (u16(at + 2, true).toLong() shl 16)
                    else (u16(at).toLong() shl 16) or u16(at + 2).toLong()
            }
            fun text(at: Int, count: Int) = String(b, at, count, Charsets.ISO_8859_1)
            fun result(w: Long, h: Long, orientation: Int = 1) =
                if (w in 1..32768 && h in 1..32768) PhotoHeader(w.toInt(), h.toInt(), orientation) else null
            if (u8(0) == 0x89 && text(1, 3) == "PNG") return result(u32(16), u32(20))
            if (text(0, 4) == "RIFF" && text(8, 4) == "WEBP") {
                return when (text(12, 4)) {
                    "VP8X" -> result(1L + u8(24) + (u8(25) shl 8) + (u8(26) shl 16),
                        1L + u8(27) + (u8(28) shl 8) + (u8(29) shl 16))
                    "VP8L" -> if (u8(20) == 0x2f) result(1L + u8(21) + ((u8(22) and 63) shl 8),
                        1L + (u8(22) shr 6) + (u8(23) shl 2) + ((u8(24) and 15) shl 10)) else null
                    "VP8 " -> if (u8(23) == 0x9d && u8(24) == 1 && u8(25) == 0x2a)
                        result((u16(26, true) and 0x3fff).toLong(), (u16(28, true) and 0x3fff).toLong()) else null
                    else -> null
                }
            }
            if (u8(0) != 255 || u8(1) != 0xd8) return null
            var at = 2
            var orientation = 1
            while (at + 4 < b.size) {
                if (u8(at) != 255) return null
                while (at < b.size && u8(at) == 255) at++
                if (at >= b.size) return null
                val marker = u8(at++)
                if (marker == 0xda || marker == 0xd9) return null
                val length = u16(at)
                if (length < 2 || at + length > b.size) return null
                if (marker in listOf(0xc0, 0xc1, 0xc2) && length >= 8)
                    return result(u16(at + 5).toLong(), u16(at + 3).toLong(), orientation)
                if (marker == 0xe1 && length >= 16 && text(at + 2, 4) == "Exif") {
                    val tiff = at + 8
                    val little = u8(tiff) == 0x49
                    val table = tiff.toLong() + u32(tiff + 4, little)
                    val end = at + length
                    if (table >= tiff && table + 2 <= end) {
                        repeat(minOf(u16(table.toInt(), little), 256)) { index ->
                            val entry = table.toInt() + 2 + index * 12
                            if (entry + 12 <= end && u16(entry, little) == 0x112 && u16(entry + 2, little) == 3 && u32(entry + 4, little) == 1L)
                                orientation = normalizedOrientation(u16(entry + 8, little))
                        }
                    }
                }
                at += length
            }
            return null
        }
    }
}
