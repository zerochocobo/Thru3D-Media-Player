package org.vrpassthroughplayer.plugin

import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.File
import java.io.InputStream

/** Probe the original response before copying its body. Ordinary JPEG posters only need a prefix. */
internal object MediaArtworkFile {
    private const val MAX_BYTES = 8 * 1024 * 1024
    private const val MAX_HEADER = 256 * 1024
    private const val MAX_PIXELS = 2_097_152L

    fun copyAnimation(source: InputStream, length: Long, destination: File): Boolean {
        if (length > MAX_BYTES) return false
        val stream = BufferedInputStream(source)
        stream.mark(MAX_HEADER)
        val animated = try { animatedHeader(DataInputStream(stream)) } catch (_: EOFException) { false }
        if (!animated) return false
        stream.reset()
        destination.outputStream().use { output ->
            val buffer = ByteArray(16384)
            var total = 0
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                total += count
                mediaRequire(total <= MAX_BYTES && !Thread.currentThread().isInterrupted, "Cover unavailable")
                output.write(buffer, 0, count)
            }
            mediaRequire(length < 0 || length == total.toLong(), "Cover unavailable")
        }
        return true
    }

    private fun animatedHeader(input: DataInputStream): Boolean {
        when (input.readInt()) {
            0x52494646 -> { // RIFF + WEBP + extended canvas with animation flag
                input.readInt()
                if (input.readInt() != 0x57454250 || input.readInt() != 0x56503858 ||
                    Integer.reverseBytes(input.readInt()) != 10 || input.readUnsignedByte() and 2 == 0) return false
                input.skipBytes(3)
                fun dimension() = 1 + input.readUnsignedByte() + (input.readUnsignedByte() shl 8) + (input.readUnsignedByte() shl 16)
                return dimension().toLong() * dimension() <= MAX_PIXELS
            }
            0x89504e47.toInt() -> {
                if (input.readInt() != 0x0d0a1a0a || input.readInt() != 13 || input.readInt() != 0x49484452) return false
                val width = input.readInt()
                val height = input.readInt()
                if (width <= 0 || height <= 0 || width.toLong() * height > MAX_PIXELS) return false
                if (input.skipBytes(9) != 9) return false
                var offset = 33
                while (offset <= MAX_HEADER - 16) {
                    val size = input.readInt()
                    when (input.readInt()) {
                        0x6163544c -> return size == 8 && input.readInt() > 1 // acTL
                        0x49444154, 0x49454e44 -> return false // IDAT / IEND
                    }
                    if (size !in 0..(MAX_HEADER - offset - 12) || input.skipBytes(size + 4) != size + 4) return false
                    offset += size + 12
                }
            }
        }
        return false
    }
}
