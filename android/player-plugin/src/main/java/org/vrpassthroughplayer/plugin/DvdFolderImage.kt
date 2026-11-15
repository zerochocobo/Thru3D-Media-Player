package org.vrpassthroughplayer.plugin

import java.io.IOException

/** A loose VIDEO_TS folder laid out as a read-only DVD-Video image, so the existing ISO
 * reader, preflight and disc menus serve it unchanged. Only the UDF structures libdvdread
 * follows are written: anchor, partition, file set, one directory and one extent per file.
 * A title set's VOB parts are adjacent, as libdvdread addresses them as one extent. */
internal object DvdFolderImage {
    const val SECTOR = 2048
    const val INDEX = "VIDEO_TS.IFO"
    private const val PARTITION = 257
    private const val MAX_FILE = 0x3FFFFFFFL // One short allocation descriptor per file.
    private val NAME = Regex("(VIDEO_TS|VTS_(\\d\\d)_(\\d))\\.(IFO|BUP|VOB)")

    class Entry(val name: String, val size: Long)
    class Extent(val name: String, val offset: Long, val size: Long)
    class Layout(val header: ByteArray, val extents: List<Extent>, val size: Long)
    class Incomplete(reason: String) : IOException("DVD folder incomplete: $reason")

    fun index(name: String) = name.equals(INDEX, true)
    /** IFO/BUP/VOB names of a disc folder, upper-cased; null for any other file. */
    fun canonical(name: String): String? = name.uppercase().takeIf { NAME.matches(it) }
    private fun set(name: String) = if (name.startsWith("VIDEO_TS")) 0 else name.substring(4, 6).toInt()

    /** Disc files of a raw folder listing (canonical name to bytes) in disc order. */
    fun select(files: Map<String, Long>): List<Entry> {
        fun size(name: String) = files[name]?.takeIf { it > 0 } ?: 0L
        fun fail(reason: String): Nothing = throw Incomplete(reason)
        if (size(INDEX) < SECTOR) fail(INDEX)
        val result = ArrayList<Entry>()
        fun add(name: String, required: Boolean = false) {
            val bytes = size(name)
            if (bytes == 0L) { if (required) fail(name); return }
            if (bytes > MAX_FILE || (name.endsWith(".VOB") && bytes % SECTOR != 0L)) fail(name)
            result.add(Entry(name, bytes))
        }
        add(INDEX, true); add("VIDEO_TS.VOB"); add("VIDEO_TS.BUP")
        val sets = files.keys.mapNotNull { name -> canonical(name)?.let(::set) }.filter { it > 0 }.toSortedSet()
        if (sets.isEmpty() || sets.last() != sets.size) fail("title sets")
        for (number in sets) {
            val stem = "VTS_%02d_".format(number)
            add("${stem}0.IFO", true); add("${stem}0.VOB"); add("${stem}1.VOB", true)
            val parts = (2..9).takeWhile { size("$stem$it.VOB") > 0 }
            if ((2..9).any { it !in parts && size("$stem$it.VOB") > 0 }) fail("$stem VOB parts")
            parts.forEach { add("$stem$it.VOB", true) }
            add("${stem}0.BUP")
        }
        return result
    }

    private fun u32(data: ByteArray, at: Int) = ((data[at].toLong() and 255) shl 24) or ((data[at + 1].toLong() and 255) shl 16) or
        ((data[at + 2].toLong() and 255) shl 8) or (data[at + 3].toLong() and 255)

    /** Checks the folder against the management tables: each IFO's first sector, read by [head]. */
    fun verify(entries: List<Entry>, head: (String) -> ByteArray) {
        fun fail(reason: String): Nothing = throw Incomplete(reason)
        val sizes = entries.associate { it.name to it.size }
        fun table(name: String, id: String): ByteArray {
            val data = head(name)
            if (data.size < 200 || String(data, 0, 12, Charsets.ISO_8859_1) != id) fail(name)
            if (sizes.getValue(name) < (u32(data, 28) + 1) * SECTOR) fail(name)
            return data
        }
        val manager = table(INDEX, "DVDVIDEO-VMG")
        val sets = entries.map { set(it.name) }.filter { it > 0 }.distinct()
        if ((((manager[62].toInt() and 255) shl 8) or (manager[63].toInt() and 255)) != sets.size) fail("title sets")
        if (u32(manager, 192) != 0L && "VIDEO_TS.VOB" !in sizes) fail("VIDEO_TS.VOB")
        for (number in sets) {
            val stem = "VTS_%02d_".format(number)
            val info = table("${stem}0.IFO", "DVDVIDEO-VTS")
            if (u32(info, 192) != 0L && "${stem}0.VOB" !in sizes) fail("${stem}0.VOB")
            // The set ends with a backup as long as the IFO; everything from vtstt_vobs up to it is title video.
            val expected = u32(info, 12) + 1 - (u32(info, 28) + 1) - u32(info, 196)
            val actual = (1..9).sumOf { sizes["$stem$it.VOB"] ?: 0L } / SECTOR
            if (u32(info, 196) != 0L && actual < expected) fail("$stem VOB size")
        }
    }

    private fun sectors(bytes: Long) = (bytes + SECTOR - 1) / SECTOR
    private fun put16(data: ByteArray, at: Int, value: Int) { data[at] = value.toByte(); data[at + 1] = (value shr 8).toByte() }
    private fun put32(data: ByteArray, at: Int, value: Long) { for (i in 0..3) data[at + i] = (value shr (8 * i)).toByte() }
    private fun text(data: ByteArray, at: Int, value: String) = value.toByteArray(Charsets.ISO_8859_1).copyInto(data, at)

    /** Descriptor tag: [location] is what the reader addresses the descriptor by. */
    private fun tag(data: ByteArray, at: Int, id: Int, length: Int, location: Long) {
        put16(data, at, id); put16(data, at + 2, 2); put16(data, at + 6, 1)
        var crc = 0
        for (i in at + 16 until at + length) {
            crc = crc xor ((data[i].toInt() and 255) shl 8)
            repeat(8) { crc = if (crc and 0x8000 != 0) (crc shl 1) xor 0x1021 else crc shl 1 }
        }
        put16(data, at + 8, crc and 0xFFFF); put16(data, at + 10, length - 16); put32(data, at + 12, location)
        data[at + 4] = (0..15).filter { it != 4 }.sumOf { data[at + it].toInt() and 255 }.toByte()
    }

    fun layout(entries: List<Entry>): Layout {
        require(entries.isNotEmpty() && entries.all { it.size in 1..MAX_FILE && canonical(it.name) == it.name })
        // Partition blocks: 0 file set, 1 terminator, 2 root entry, 3 root directory, 4 VIDEO_TS entry,
        // 5.. VIDEO_TS directory, then one file entry per file, then the files themselves.
        val record = 4 * ((38 + 1 + 8 + 3) / 4)
        val directoryBytes = 40 + entries.sumOf { 4 * ((38 + 1 + it.name.length + 3) / 4) }
        val firstEntry = 5 + sectors(directoryBytes.toLong()).toInt()
        var block = (firstEntry + entries.size).toLong()
        val blocks = entries.map { entry -> block.also { block += sectors(entry.size) } }
        val header = ByteArray((PARTITION + firstEntry + entries.size) * SECTOR)
        fun volume(sector: Int) = sector * SECTOR
        fun inside(at: Int) = volume(PARTITION + at)

        listOf("BEA01", "NSR02", "TEA01").forEachIndexed { i, id -> text(header, volume(16 + i) + 1, id); header[volume(16 + i) + 6] = 1 }
        var at = volume(32) // Primary volume descriptor
        put32(header, at + 16, 1); header[at + 24] = 8; text(header, at + 25, "DVD_VIDEO"); header[at + 55] = 10
        put16(header, at + 56, 1); put16(header, at + 58, 1); put16(header, at + 60, 2); put16(header, at + 62, 1)
        tag(header, at, 1, 512, 32)
        at = volume(33) // Partition descriptor
        put32(header, at + 16, 2); put16(header, at + 20, 1); text(header, at + 25, "+NSR02")
        put32(header, at + 184, 1); put32(header, at + 188, PARTITION.toLong()); put32(header, at + 192, block)
        tag(header, at, 5, 512, 33)
        at = volume(34) // Logical volume descriptor
        put32(header, at + 16, 3); header[at + 84] = 8; text(header, at + 85, "DVD_VIDEO"); header[at + 211] = 10
        put32(header, at + 212, SECTOR.toLong()); text(header, at + 217, "*OSTA UDF Compliant"); put16(header, at + 240, 0x102)
        put32(header, at + 248, SECTOR.toLong()); put32(header, at + 264, 6); put32(header, at + 268, 1)
        header[at + 440] = 1; header[at + 441] = 6; put16(header, at + 442, 1)
        tag(header, at, 6, 446, 34)
        tag(header, volume(35), 8, 512, 35)
        at = volume(256) // Anchor
        put32(header, at + 16, 4L * SECTOR); put32(header, at + 20, 32); put32(header, at + 24, 4L * SECTOR); put32(header, at + 28, 32)
        tag(header, at, 2, 512, 256)

        at = inside(0) // File set descriptor: the root directory entry is block 2.
        put32(header, at + 400, SECTOR.toLong()); put32(header, at + 404, 2)
        tag(header, at, 256, 512, 0)
        tag(header, inside(1), 8, 512, 1)
        fun fileEntry(at: Int, type: Int, bytes: Long, data: Long) {
            val start = inside(at)
            put16(header, start + 20, 4); put16(header, start + 24, 1); header[start + 27] = type.toByte()
            put32(header, start + 56, bytes); put32(header, start + 64, sectors(bytes))
            put32(header, start + 172, 8); put32(header, start + 176, bytes); put32(header, start + 180, data)
            tag(header, start, 261, 184, at.toLong())
        }
        /** File identifier: characteristics 2 directory, 8 parent. Returns the next record. */
        fun identifier(start: Int, location: Long, name: String, characteristics: Int, entry: Long): Int {
            val length = 4 * ((38 + (if (name.isEmpty()) 0 else 1 + name.length) + 3) / 4)
            put16(header, start + 16, 1); header[start + 18] = characteristics.toByte()
            put32(header, start + 20, SECTOR.toLong()); put32(header, start + 24, entry)
            if (name.isNotEmpty()) { header[start + 19] = (1 + name.length).toByte(); header[start + 38] = 8; text(header, start + 39, name) }
            tag(header, start, 257, length, location)
            return start + length
        }
        fileEntry(2, 4, (40 + record).toLong(), 3)
        identifier(identifier(inside(3), 3, "", 10, 2), 3, "VIDEO_TS", 2, 4)
        fileEntry(4, 4, directoryBytes.toLong(), 5)
        at = identifier(inside(5), 5, "", 10, 2)
        entries.forEachIndexed { i, entry ->
            at = identifier(at, 5L + (at - inside(5)) / SECTOR, entry.name, 0, (firstEntry + i).toLong())
            fileEntry(firstEntry + i, 5, entry.size, blocks[i])
        }
        val extents = entries.mapIndexed { i, entry -> Extent(entry.name, (PARTITION + blocks[i]) * SECTOR, entry.size) }
        return Layout(header, extents, (PARTITION + block) * SECTOR)
    }
}
