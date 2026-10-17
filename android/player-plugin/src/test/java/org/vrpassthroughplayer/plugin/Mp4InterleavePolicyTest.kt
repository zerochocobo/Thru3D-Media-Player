package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream

class Mp4InterleavePolicyTest {
    private val mib = 1024L * 1024
    private fun numbers(vararg values: Long) = ByteArrayOutputStream().also { out ->
        DataOutputStream(out).use { data -> values.forEach { data.writeInt(it.toInt()) } }
    }.toByteArray()
    private fun box(type: String, vararg contents: ByteArray): ByteArray {
        val payload = contents.fold(ByteArray(0)) { a, b -> a + b }
        return numbers(payload.size + 8L) + type.toByteArray(Charsets.US_ASCII) + payload
    }
    private fun offsets(values: LongArray, wide: Boolean): ByteArray {
        val data = ByteArrayOutputStream(); DataOutputStream(data).use { out ->
            out.writeInt(0); out.writeInt(values.size)
            values.forEach { if (wide) out.writeLong(it) else out.writeInt(it.toInt()) }
        }
        return box(if (wide) "co64" else "stco", data.toByteArray())
    }
    private fun track(kind: String, positions: LongArray, sizes: LongArray, wide: Boolean) = box("trak",
        box("mdia", box("hdlr", numbers(0, 0), kind.toByteArray()),
            box("minf", box("stbl", offsets(positions, wide), box("stsz", numbers(0, 0, sizes.size.toLong(), *sizes))))))
    private class SparseReader(val head: ByteArray, val moov: ByteArray, val moovAt: Long) : Mp4InterleavePolicy.Reader {
        override val size = moovAt + moov.size
        val reads = ArrayList<Pair<Long, Int>>()
        override fun read(offset: Long, length: Int): ByteArray {
            reads.add(offset to length)
            val count = minOf(length.toLong(), size - offset).toInt()
            return ByteArray(count) { i ->
                val at = offset + i
                when { at < head.size -> head[at.toInt()]; at >= moovAt -> moov[(at - moovAt).toInt()]; else -> 0 }
            }
        }
    }
    private fun fixture(normal: Boolean = false, wide: Boolean = true, audioSize: Long = 32 * mib,
                        multipleAudio: Boolean = false, fragmented: Boolean = false, withAudio: Boolean = true): SparseReader {
        val prefix = audioSize * 3
        val videoAt = if (normal) mib + 44 else prefix + 44
        val moovAt = if (wide) 5L * 1024 * mib else 240 * mib
        val audioPositions = if (normal) longArrayOf(44, 2 * mib + 44, 4 * mib + 44, 6 * mib + 44)
            else longArrayOf(44, audioSize + 44, audioSize * 2 + 44, moovAt - 512)
        val audio = track("soun", audioPositions, longArrayOf(audioSize, audioSize, audioSize, 512), wide)
        val video = track("vide", longArrayOf(videoAt, if (wide) 4L * 1024 * mib else videoAt + mib), longArrayOf(mib, mib), wide)
        val tracks = video + (if (withAudio) audio else ByteArray(0)) + (if (multipleAudio) audio else ByteArray(0)) +
            (if (fragmented) box("mvex") else ByteArray(0))
        val moov = box("moov", tracks)
        val ftyp = box("ftyp", "isom".toByteArray(), numbers(0), "isommp41".toByteArray())
        val mdat = ByteArrayOutputStream().also { out -> DataOutputStream(out).use {
            it.writeInt(1); it.writeBytes("mdat"); it.writeLong(moovAt - ftyp.size)
        } }.toByteArray()
        return SparseReader(ftyp + mdat, moov, moovAt)
    }
    @Test fun resolveStyleAudioPrefixUsesSequentialReadWithoutReadingMediaPayload() {
        val reader = fixture()
        val decision = Mp4InterleavePolicy.inspect(reader)
        assertTrue(decision.sequential); assertEquals(96 * mib, decision.leadingAudioBytes)
        assertEquals(listOf(0L, reader.moovAt), reader.reads.map { it.first })
        assertTrue(reader.reads.sumOf { minOf(it.second.toLong(), reader.size - it.first) } < 65536)
    }
    @Test fun ordinaryInterleavingAnd32BitChunkOffsetsKeepTheExistingPolicy() {
        assertFalse(Mp4InterleavePolicy.inspect(fixture(normal = true)).sequential)
        assertFalse(Mp4InterleavePolicy.inspect(fixture(normal = true, wide = false)).sequential)
        assertTrue(Mp4InterleavePolicy.inspect(fixture(wide = false)).sequential)
    }
    @Test fun largeAudioMultipleSelectionsSilentAndFragmentedFilesNeverOptIn() {
        assertFalse(Mp4InterleavePolicy.inspect(fixture(audioSize = 64 * mib)).sequential)
        assertFalse(Mp4InterleavePolicy.inspect(fixture(multipleAudio = true)).sequential)
        assertFalse(Mp4InterleavePolicy.inspect(fixture(withAudio = false)).sequential)
        assertFalse(Mp4InterleavePolicy.inspect(fixture(fragmented = true)).sequential)
    }
    @Test fun smallerAudioPrefixesKeepTheNormalLowLatencyPolicy() {
        assertFalse(Mp4InterleavePolicy.inspect(fixture(audioSize = 4 * mib)).sequential)
    }
    @Test fun missingMetadataInvalidLengthsAndUnsupportedContainersFailOpen() {
        val f = fixture()
        assertFalse(Mp4InterleavePolicy.inspect(SparseReader(f.head, ByteArray(8), f.moovAt)).sequential)
        assertFalse(Mp4InterleavePolicy.inspect(SparseReader(box("free", numbers(0, 0)), f.moov, f.moovAt)).sequential)
        val corrupt = f.moov.copyOf(); for (i in 0..3) corrupt[i] = 0x7f
        assertFalse(Mp4InterleavePolicy.inspect(SparseReader(f.head, corrupt, f.moovAt)).sequential)
        val throwing = object : Mp4InterleavePolicy.Reader {
            override val size = 100L
            override fun read(offset: Long, length: Int): ByteArray = throw java.io.IOException("No Range")
        }
        assertFalse(Mp4InterleavePolicy.inspect(throwing).sequential)
    }
    @Test fun cancellationUnsupportedSchemesAndCredentialsMakeNoHttpRequests() {
        assertFalse(Mp4InterleavePolicy.inspectHttp("http://127.0.0.1:1/a.mp4") { true }.sequential)
        for (url in listOf("file:///a.mp4", "http://user:pass@127.0.0.1:1/a.mp4"))
            assertFalse(Mp4InterleavePolicy.inspectHttp(url).sequential)
    }
    @Test fun httpUsesBoundedRangesAndRejectsServersThatIgnoreOrLieAboutRanges() {
        val source = fixture()
        val server = java.net.ServerSocket(0, 8, java.net.InetAddress.getByName("127.0.0.1"))
        val mode = java.util.concurrent.atomic.AtomicInteger(206)
        val delayFirstHeader = java.util.concurrent.atomic.AtomicBoolean(true)
        val worker = Thread {
            while (!server.isClosed) {
                val socket = try { server.accept() } catch (_: java.io.IOException) { break }
                runCatching { socket.use {
                    it.soTimeout = 2000
                    val input = it.getInputStream().bufferedReader()
                    val lines = generateSequence { input.readLine() }.takeWhile { line -> line.isNotEmpty() }.toList()
                    val value = lines.single { line -> line.startsWith("Range:", true) }.substringAfter(':').trim()
                    val range = Regex("bytes=([0-9]+)-([0-9]+)").matchEntire(value)!!
                    val start = range.groupValues[1].toLong(); val end = minOf(range.groupValues[2].toLong(), source.size - 1)
                    val bytes = source.read(start, (end - start + 1).toInt()); val selected = mode.get()
                    // Cloud resolve/CDN headers can take >1 second even when the transfer is fast.
                    if (delayFirstHeader.compareAndSet(true, false)) Thread.sleep(1100)
                    val headers = "HTTP/1.1 ${if (selected == 201) 206 else selected} OK\r\nContent-Length: ${bytes.size}\r\n" +
                        "Content-Range: bytes ${if (selected == 201) start + 1 else start}-$end/${source.size}\r\nConnection: close\r\n\r\n"
                    it.getOutputStream().write(headers.toByteArray(Charsets.US_ASCII)); it.getOutputStream().write(bytes)
                } }
            }
        }.apply { isDaemon = true; start() }
        try {
            val url = "http://127.0.0.1:${server.localPort}/opaque.bin"
            assertTrue(Mp4InterleavePolicy.inspectHttp(url).sequential)
            mode.set(200); assertFalse(Mp4InterleavePolicy.inspectHttp(url).sequential)
            mode.set(201); assertFalse(Mp4InterleavePolicy.inspectHttp(url).sequential)
        } finally { server.close(); worker.join(3000) }
    }
}
