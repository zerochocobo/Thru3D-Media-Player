package org.vrpassthroughplayer.plugin

import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.zip.Deflater
import java.util.zip.Inflater

/** Depth maps of viewed photos kept between openings: an entry is named after the picture's own
 * bytes, so no path, account or title is written. Stereo pairs are rebuilt from the map.
 * Disposable like the other photo caches (PhotoCache clears and counts this directory). */
internal class PhotoDepthStore(cache: File, private val limit: Long = 256L * 1024 * 1024) {
    class Entry(val near: ByteBuffer, val rect: FloatArray)

    private val root = File(cache, NAME)

    /** [variant] separates maps of one file that differ by model or by the eye they describe. */
    fun key(source: File, variant: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        source.inputStream().use { input ->
            val bytes = ByteArray(1 shl 16)
            while (true) { val count = input.read(bytes); if (count < 0) break; digest.update(bytes, 0, count) }
        }
        digest.update(variant.toByteArray())
        return digest.digest().take(20).joinToString("") { "%02x".format(it) }
    }

    /** Float32 near map (width x height, little endian) or null: absent, another size, or damaged. */
    fun get(key: String, width: Int, height: Int): Entry? = synchronized(lock) {
        val file = File(root, "$key.$EXTENSION")
        if (!file.isFile) return null
        val entry = runCatching {
            val data = ByteBuffer.wrap(file.readBytes()).order(ByteOrder.LITTLE_ENDIAN)
            require(data.remaining() > HEADER && data.int == MAGIC && data.int == width && data.int == height)
            val rect = FloatArray(4) { data.float }
            require(rect.all { it.isFinite() && it in 0f..1f } && rect[2] > 0f && rect[3] > 0f)
            val levels = ByteArray(width * height * 2)
            val inflater = Inflater()
            try {
                inflater.setInput(data.array(), data.position(), data.remaining())
                var filled = 0
                while (filled < levels.size) {
                    val count = inflater.inflate(levels, filled, levels.size - filled)
                    require(count > 0)
                    filled += count
                }
                require(inflater.finished() || inflater.inflate(ByteArray(1)) == 0)
            } finally { inflater.end() }
            val packed = ByteBuffer.wrap(levels).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
            val near = ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.LITTLE_ENDIAN)
            repeat(width * height) { near.putFloat((packed.get().toInt() and 0xffff) / 65535f) }
            near.rewind()
            Entry(near, rect)
        }.getOrNull()
        if (entry == null) file.delete() else file.setLastModified(System.currentTimeMillis())
        entry
    }

    /** [near]: float32 in [0, 1] from its current position; the oldest entries make room. */
    fun put(key: String, near: ByteBuffer, width: Int, height: Int, rect: FloatArray): Boolean = synchronized(lock) {
        runCatching {
            require(rect.size == 4 && near.remaining() == width * height * 4)
            val values = near.duplicate().order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
            val levels = ByteBuffer.allocate(width * height * 2).order(ByteOrder.LITTLE_ENDIAN)
            var low = Float.MAX_VALUE; var high = -Float.MAX_VALUE
            repeat(width * height) {
                val value = values.get()
                require(value.isFinite())
                low = minOf(low, value); high = maxOf(high, value)
                levels.putShort((value.coerceIn(0f, 1f) * 65535f + 0.5f).toInt().toShort())
            }
            // One value everywhere is a failed conversion or a blank picture: neither is worth keeping.
            require(high > low)
            val packed = ByteArrayOutputStream(width * height)
            val header = ByteBuffer.allocate(HEADER).order(ByteOrder.LITTLE_ENDIAN).putInt(MAGIC).putInt(width).putInt(height)
            rect.forEach { header.putFloat(it) }
            packed.write(header.array())
            val deflater = Deflater(Deflater.BEST_SPEED)
            try {
                deflater.setInput(levels.array()); deflater.finish()
                val chunk = ByteArray(1 shl 16)
                while (!deflater.finished()) packed.write(chunk, 0, deflater.deflate(chunk))
            } finally { deflater.end() }
            root.mkdirs()
            val temporary = File(root, "$key.tmp")
            try {
                temporary.writeBytes(packed.toByteArray())
                val target = File(root, "$key.$EXTENSION")
                target.delete()
                require(temporary.renameTo(target))
            } finally { temporary.delete() }
            prune()
            true
        }.getOrDefault(false)
    }

    private fun prune() {
        val entries = root.listFiles()?.filter { it.extension == EXTENSION }?.sortedBy { it.lastModified() } ?: return
        var total = entries.sumOf { it.length() }
        for (entry in entries) {
            if (total <= limit) break
            total -= entry.length()
            entry.delete()
        }
    }

    companion object {
        const val NAME = "photo-depth-store"
        private const val EXTENSION = "d16"
        private const val MAGIC = 0x36314454 // "TD16"
        private const val HEADER = 28
        private val lock = Any()
    }
}
