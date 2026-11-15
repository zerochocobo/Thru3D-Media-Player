package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile

class DvdFolderImageTest {
    private val sector = DvdFolderImage.SECTOR
    private class Bytes(val data: ByteArray) : StreamSource {
        override val size = data.size.toLong()
        var closed = false
        override fun open() = object : StreamSource.Reader {
            override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
                val n = minOf(length.toLong(), size - offset, 700).toInt() // Short reads, as a socket gives.
                data.copyInto(buffer, 0, offset.toInt(), offset.toInt() + n)
                return n
            }
            override fun close() {}
        }
        override fun close() { closed = true }
    }

    private fun put32(data: ByteArray, at: Int, value: Int) { for (i in 0..3) data[at + i] = (value shr (24 - 8 * i)).toByte() }
    /** A management table of [sectors]; [last] is the final sector of its whole set. */
    private fun ifo(id: String, sectors: Int, last: Int, menu: Int, titles: Int, sets: Int = 0) = ByteArray(sectors * sector).also {
        id.toByteArray().copyInto(it); put32(it, 12, last); put32(it, 28, sectors - 1)
        it[63] = sets.toByte(); put32(it, 192, menu); put32(it, 196, titles)
        for (i in 256 until it.size) it[i] = (i * 7 + id.length).toByte()
    }
    private fun vob(sectors: Int, seed: Int) = ByteArray(sectors * sector) { (it / 3 + seed).toByte() }

    /** One set: 2-sector IFO, 3-sector menu, title parts of 5 + 4 sectors, 2-sector backup. */
    private fun disc(): LinkedHashMap<String, ByteArray> = linkedMapOf(
        "VIDEO_TS.IFO" to ifo("DVDVIDEO-VMG", 1, 3, 1, 0, sets = 1),
        "VIDEO_TS.VOB" to vob(2, 1),
        "VIDEO_TS.BUP" to ifo("DVDVIDEO-VMG", 1, 3, 1, 0, sets = 1),
        "VTS_01_0.IFO" to ifo("DVDVIDEO-VTS", 2, 15, 2, 5),
        "VTS_01_0.VOB" to vob(3, 2),
        "VTS_01_1.VOB" to vob(5, 3),
        "VTS_01_2.VOB" to vob(4, 4),
        "VTS_01_0.BUP" to ifo("DVDVIDEO-VTS", 2, 15, 2, 5))

    private fun source(files: Map<String, ByteArray>, opened: MutableList<String> = ArrayList()) =
        DvdFolderSource.of(files.map { it.key to it.value.size.toLong() }) { name -> opened.add(name); Bytes(files.getValue(name)) }

    private fun readAll(source: StreamSource): ByteArray {
        val image = ByteArray(source.size.toInt())
        source.open().use { reader ->
            var at = 0
            val buffer = ByteArray(5000)
            while (at < image.size) {
                val n = reader.read(at.toLong(), buffer, minOf(buffer.size, image.size - at))
                assertTrue(n > 0); buffer.copyInto(image, at, 0, n); at += n
            }
        }
        return image
    }

    private fun le16(d: ByteArray, at: Int) = (d[at].toInt() and 255) or ((d[at + 1].toInt() and 255) shl 8)
    private fun le32(d: ByteArray, at: Int) = le16(d, at) or (le16(d, at + 2) shl 16)

    /** Follows the same descriptors as libdvdread's UDFFindFile; file name to (sector, bytes). */
    private fun udfFiles(image: ByteArray): Map<String, Pair<Int, Int>> {
        assertEquals(2, le16(image, 256 * sector))
        var at = le32(image, 256 * sector + 20) * sector
        var start = -1
        var logical = false
        while (le16(image, at) != 8) {
            if (le16(image, at) == 5 && le16(image, at + 22) == 0) start = le32(image, at + 188)
            if (le16(image, at) == 6) logical = le32(image, at + 212) == sector
            at += sector
        }
        assertTrue(start > 0 && logical)
        fun block(n: Int) = (start + n) * sector
        assertEquals(256, le16(image, block(0)))
        fun entry(icb: Int): Triple<Int, Int, Int> { // type, location, length
            val e = block(icb)
            assertEquals(261, le16(image, e)); assertEquals(0, le16(image, e + 34) and 7); assertEquals(8, le32(image, e + 172))
            val descriptor = e + 176 + le32(image, e + 168)
            return Triple(image[e + 27].toInt(), le32(image, descriptor + 4), le32(image, descriptor) and 0x3FFFFFFF)
        }
        fun scan(directory: Triple<Int, Int, Int>): Map<String, Int> {
            assertEquals(4, directory.first)
            val found = LinkedHashMap<String, Int>()
            var p = block(directory.second)
            val end = p + directory.third
            while (p < end) {
                assertEquals(257, le16(image, p))
                val length = image[p + 19].toInt() and 255
                if (length > 0) { assertEquals(8, image[p + 38].toInt()); found[String(image, p + 39, length - 1)] = le32(image, p + 24) }
                p += 4 * ((38 + length + le16(image, p + 36) + 3) / 4)
            }
            assertEquals(end, p)
            return found
        }
        val root = scan(entry(le32(image, block(0) + 404)))
        assertEquals(setOf("VIDEO_TS"), root.keys)
        return scan(entry(root.getValue("VIDEO_TS"))).mapValues { (_, icb) ->
            val file = entry(icb)
            assertEquals(5, file.first)
            (start + file.second) to file.third
        }
    }

    @Test fun folderFilesAreFoundThroughTheUdfDirectoryAtTheirExtents() {
        val files = disc()
        val image = readAll(source(files))
        val found = udfFiles(image)
        assertEquals(files.keys.toList(), found.keys.toList())
        for ((name, at) in found) assertArrayEquals(name, files.getValue(name), image.copyOfRange(at.first * sector, at.first * sector + at.second))
        // libdvdread reads a set's title parts as one extent starting at part 1.
        assertEquals(found.getValue("VTS_01_1.VOB").first + 5, found.getValue("VTS_01_2.VOB").first)
        assertEquals(0, image.size % sector)
    }

    @Test fun manyFilesSpanSeveralDirectoryBlocks() {
        val files = LinkedHashMap<String, ByteArray>()
        files["VIDEO_TS.IFO"] = ifo("DVDVIDEO-VMG", 1, 1, 0, 0, sets = 60)
        for (set in 1..60) {
            files["VTS_%02d_0.IFO".format(set)] = ifo("DVDVIDEO-VTS", 1, 2, 0, 1)
            files["VTS_%02d_1.VOB".format(set)] = vob(1, set)
        }
        val image = readAll(source(files))
        val found = udfFiles(image)
        assertEquals(121, found.size)
        for ((name, at) in found) assertArrayEquals(files.getValue(name), image.copyOfRange(at.first * sector, at.first * sector + at.second))
    }

    @Test fun namesAreCaseInsensitiveAndOtherFilesAreIgnored() {
        val files = LinkedHashMap<String, ByteArray>()
        disc().forEach { (name, data) -> files[name.lowercase()] = data }
        files["movie.nfo"] = ByteArray(10); files["VTS_01_0.IFO.bak"] = ByteArray(10)
        val opened = ArrayList<String>()
        val found = udfFiles(readAll(source(files, opened)))
        assertEquals(disc().keys.toList(), found.keys.toList())
        assertTrue(opened.all { it == it.lowercase() })
    }

    @Test fun onlyTheFilesBeingReadAreOpened() {
        val opened = ArrayList<String>()
        val source = source(disc(), opened)
        assertEquals(listOf("VIDEO_TS.IFO", "VTS_01_0.IFO"), opened) // The verification pass.
        val layout = DvdFolderImage.layout(DvdFolderImage.select(disc().mapValues { it.value.size.toLong() }))
        val title = layout.extents.first { it.name == "VTS_01_1.VOB" }
        val buffer = ByteArray(4096)
        source.open().use { assertTrue(it.read(title.offset + 100, buffer, buffer.size) > 0) }
        assertEquals(listOf("VIDEO_TS.IFO", "VTS_01_0.IFO", "VTS_01_1.VOB"), opened)
        source.close()
    }

    @Test fun paddingAfterAShortFileReadsAsZero() {
        val files = disc()
        files["VIDEO_TS.IFO"] = files.getValue("VIDEO_TS.IFO") + ByteArray(100) { 9 }
        val image = readAll(source(files))
        val at = udfFiles(image).getValue("VIDEO_TS.IFO")
        assertEquals(sector + 100, at.second)
        assertTrue(image.copyOfRange(at.first * sector + sector + 100, at.first * sector + 2 * sector).all { it == 0.toByte() })
    }

    private fun rejected(change: (LinkedHashMap<String, ByteArray>) -> Unit): Boolean {
        val files = disc().also(change)
        return try { source(files).close(); false } catch (_: DvdFolderImage.Incomplete) { true }
    }

    @Test fun incompleteFoldersAreNotDiscs() {
        assertFalse(rejected {})
        assertFalse(rejected { it.remove("VIDEO_TS.BUP"); it.remove("VTS_01_0.BUP") })
        assertTrue(rejected { it.remove("VIDEO_TS.IFO") })
        assertTrue(rejected { it.remove("VTS_01_0.IFO") })
        assertTrue(rejected { it.remove("VTS_01_1.VOB") })
        assertTrue(rejected { it.remove("VTS_01_2.VOB") }) // Title video shorter than its table says.
        assertTrue(rejected { it["VTS_01_2.VOB"] = vob(3, 4) })
        assertTrue(rejected { it["VTS_01_2.VOB"] = ByteArray(4 * sector - 1) })
        assertTrue(rejected { it["VTS_01_4.VOB"] = vob(1, 5) }) // Part 3 is missing.
        assertTrue(rejected { it.remove("VTS_01_0.VOB") }) // The table names a menu.
        assertTrue(rejected { it.remove("VIDEO_TS.VOB") })
        assertTrue(rejected { it["VTS_03_0.IFO"] = ifo("DVDVIDEO-VTS", 1, 2, 0, 1); it["VTS_03_1.VOB"] = vob(1, 1) })
        assertTrue(rejected { it["VTS_01_0.IFO"] = ifo("DVDVIDEO-VMG", 2, 15, 2, 5) })
        assertTrue(rejected { it["VTS_01_0.IFO"] = it.getValue("VTS_01_0.IFO").copyOf(sector) })
        assertTrue(rejected { it["video_ts.ifo"] = it.getValue("VIDEO_TS.IFO") })
        assertTrue(rejected { it["VIDEO_TS.IFO"] = ifo("DVDVIDEO-VMG", 1, 3, 1, 0, sets = 2) })
    }

    @Test fun emptyOptionalFilesAreLeftOut() {
        val files = disc()
        files["VIDEO_TS.IFO"] = ifo("DVDVIDEO-VMG", 1, 1, 0, 0, sets = 1)
        files["VIDEO_TS.VOB"] = ByteArray(0)
        assertFalse("VIDEO_TS.VOB" in udfFiles(readAll(source(files))))
    }

    @Test fun aFileThatChangedSizeFailsTheRead() {
        val files = disc()
        val source = DvdFolderSource.of(files.map { it.key to it.value.size.toLong() }) { name ->
            Bytes(if (name == "VTS_01_1.VOB") vob(4, 3) else files.getValue(name))
        }
        val at = DvdFolderImage.layout(DvdFolderImage.select(files.mapValues { it.value.size.toLong() })).extents.first { it.name == "VTS_01_1.VOB" }.offset
        try { source.open().use { it.read(at, ByteArray(10), 10) }; fail() } catch (_: java.io.IOException) {}
    }

    @Test fun closingReleasesEveryOpenedFile() {
        val parts = ArrayList<Bytes>()
        val files = disc()
        val source = DvdFolderSource.of(files.map { it.key to it.value.size.toLong() }) { Bytes(files.getValue(it)).also(parts::add) }
        val fork = source.fork()
        readAll(fork); readAll(source)
        source.close(); fork.close()
        assertTrue(parts.size > 8 && parts.all { it.closed })
    }

    @Test fun publishedAsAnIsoItServesTheSameImageThroughTheDiscReadCache() {
        val files = disc()
        val image = readAll(source(files))
        val server = LocalStreamServer()
        try {
            val url = server.publish(source(files), "video.iso", IsoMetadataMemory.key("test", image.size))
            assertNotNull(server.isoCacheStats(url))
            val random = java.util.Random(7)
            val starts = listOf(0, 256 * sector, image.size - 10) + List(40) { random.nextInt(image.size) }
            for (start in starts) {
                val end = minOf(image.size, start + 1 + random.nextInt(3 * sector)) - 1
                val connection = java.net.URL(url).openConnection() as java.net.HttpURLConnection
                connection.setRequestProperty("Range", "bytes=$start-$end")
                assertEquals(206, connection.responseCode)
                assertArrayEquals("range $start-$end", image.copyOfRange(start, end + 1), connection.inputStream.use { it.readBytes() })
            }
        } finally { server.close(); IsoMetadataMemory.clear() }
    }

    @Test fun onlyTheDiscIndexIsListed() {
        assertTrue(MediaKinds.supportedFileName("VIDEO_TS.IFO") && MediaKinds.supportedFileName("video_ts.ifo"))
        assertEquals("video", MediaKinds.fileNameKind("VIDEO_TS.IFO"))
        assertFalse(MediaKinds.supportedFileName("VTS_01_0.IFO") || MediaKinds.supportedFileName("VIDEO_TS.BUP"))
    }

    /** Host check against a real folder: THRU3D_DVD_FOLDER=<VIDEO_TS> THRU3D_DVD_IMAGE=<output .iso>. */
    @Test fun writesARealFolderAsAnImage() {
        val folder = System.getenv("THRU3D_DVD_FOLDER").orEmpty()
        val output = System.getenv("THRU3D_DVD_IMAGE").orEmpty()
        assumeTrue(folder.isNotEmpty() && output.isNotEmpty())
        val files = File(folder).listFiles()!!.filter { it.isFile }
        val source = DvdFolderSource.of(files.map { it.name to it.length() }) { name ->
            val file = RandomAccessFile(File(folder, name), "r")
            object : StreamSource {
                override val size = file.length()
                override fun open() = object : StreamSource.Reader {
                    override fun read(offset: Long, buffer: ByteArray, length: Int): Int = synchronized(file) { file.seek(offset); file.read(buffer, 0, length) }
                    override fun close() {}
                }
                override fun close() = file.close()
            }
        }
        File(output).outputStream().buffered(1 shl 20).use { out ->
            source.open().use { reader ->
                val buffer = ByteArray(1 shl 20)
                var at = 0L
                while (at < source.size) {
                    val n = reader.read(at, buffer, minOf(buffer.size.toLong(), source.size - at).toInt())
                    out.write(buffer, 0, n); at += n
                }
            }
        }
        source.close()
        assertEquals(File(output).length(), source.size)
    }
}
