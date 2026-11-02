package org.vrpassthroughplayer.plugin

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteOrder
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The last steps before a crash, in a memory-mapped ring: a write only touches memory, and the kernel
 * still flushes the page when the process dies, so even a native crash keeps the step that caused it.
 * The header doubles as the session marker (pid, start, clean exit, foreground). Entries carry stage
 * names, sizes and counts only, never paths, titles or accounts.
 */
internal object CrashTrail {
    private const val MAGIC = 0x54335452 // "T3TR"
    private const val VERSION = 1
    private const val HEADER = 32
    const val SLOTS = 512
    private const val SLOT = 192
    private const val TEXT = SLOT - 10
    private const val CLEAN = 1
    private const val FOREGROUND = 2

    class Session(val pid: Int, val startedMs: Long, val clean: Boolean, val foreground: Boolean, val lines: List<String>)

    @Volatile private var buffer: MappedByteBuffer? = null

    /** Maps [file], returns the session it held (null if none or unreadable) and starts this one. */
    @Synchronized fun open(file: File, pid: Int, nowMs: Long = System.currentTimeMillis()): Session? {
        file.parentFile?.mkdirs()
        val map = RandomAccessFile(file, "rw").use { raf ->
            raf.setLength((HEADER + SLOTS * SLOT).toLong())
            raf.channel.map(FileChannel.MapMode.READ_WRITE, 0, (HEADER + SLOTS * SLOT).toLong())
        }.apply { order(ByteOrder.LITTLE_ENDIAN) }
        val previous = runCatching { read(map) }.getOrNull()
        for (index in 0 until HEADER + SLOTS * SLOT step 8) map.putLong(index, 0L)
        map.putInt(0, MAGIC); map.putInt(4, VERSION); map.putInt(8, 0); map.putInt(12, pid)
        map.putLong(16, nowMs); map.putInt(24, FOREGROUND)
        buffer = map
        return previous
    }

    private fun read(map: MappedByteBuffer): Session? {
        if (map.getInt(0) != MAGIC || map.getInt(4) != VERSION) return null
        val next = map.getInt(8).coerceAtLeast(0)
        val flags = map.getInt(24)
        val time = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
        val lines = (maxOf(0, next - SLOTS) until next).mapNotNull { index ->
            val base = HEADER + (index % SLOTS) * SLOT
            val length = map.getShort(base + 8).toInt()
            if (length !in 1..TEXT) return@mapNotNull null
            val bytes = ByteArray(length)
            for (offset in 0 until length) bytes[offset] = map.get(base + 10 + offset)
            time.format(Date(map.getLong(base))) + " " + String(bytes, Charsets.UTF_8)
        }
        return Session(map.getInt(12), map.getLong(16), flags and CLEAN != 0, flags and FOREGROUND != 0, lines)
    }

    /** One step: "photo.decode", "w=4000 h=3000 sample=2". Cheap enough for every image, not every frame. */
    fun mark(stage: String, detail: String = "") {
        val map = buffer ?: return
        val text = "[" + Thread.currentThread().name.take(24) + "] " + stage + (if (detail.isEmpty()) "" else " $detail")
        val bytes = text.toByteArray(Charsets.UTF_8).let { if (it.size > TEXT) it.copyOf(TEXT) else it }
        synchronized(this) {
            val index = map.getInt(8)
            val base = HEADER + (index % SLOTS) * SLOT
            map.putLong(base, System.currentTimeMillis())
            map.putShort(base + 8, bytes.size.toShort())
            for (offset in bytes.indices) map.put(base + 10 + offset, bytes[offset])
            map.putInt(8, index + 1)
        }
    }

    fun foreground(value: Boolean) = setFlag(FOREGROUND, value)
    fun cleanExit() = setFlag(CLEAN, true)

    private fun setFlag(flag: Int, value: Boolean) {
        val map = buffer ?: return
        synchronized(this) { map.putInt(24, if (value) map.getInt(24) or flag else map.getInt(24) and flag.inv()) }
    }

    /** This session's steps so far, oldest first, for a log saved without a crash. */
    fun current(): List<String> = synchronized(this) { buffer?.let { runCatching { read(it)?.lines }.getOrNull() } ?: emptyList() }

    /** Tests only. */
    internal fun detach() { buffer = null }
}
