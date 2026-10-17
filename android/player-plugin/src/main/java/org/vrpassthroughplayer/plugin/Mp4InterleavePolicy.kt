package org.vrpassthroughplayer.plugin

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI

/** A bounded metadata check; never scans mdat, changes the file, or probes a decoder.
 * Only a small, almost complete audio track preceding one video track is eligible.
 * 128 MiB leaves at least half of the existing 256 MiB demux cache for video. */
internal object Mp4InterleavePolicy {
    const val MAX_AUDIO_BYTES = 128L * 1024 * 1024
    const val MAX_METADATA_BYTES = 8 * 1024 * 1024
    private const val HEAD_BYTES = 32 * 1024
    private const val MIN_AUDIO_BYTES = 32L * 1024 * 1024
    data class Decision(val sequential: Boolean = false, val leadingAudioBytes: Long = 0, val diagnostic: String = "default")
    private fun fallback(error: Exception) = Decision(diagnostic = error.javaClass.simpleName + ":" +
        (error.stackTrace.firstOrNull { it.className.startsWith(Mp4InterleavePolicy::class.java.name) }?.lineNumber ?: 0))
    interface Reader {
        val size: Long
        fun read(offset: Long, length: Int): ByteArray
    }

    fun inspect(reader: Reader): Decision = try {
        val head = reader.read(0, HEAD_BYTES)
        require(head.size >= 16 && type(head, 4) == "ftyp")
        var offset = 0L
        var window = head
        var windowOffset = 0L
        var result = Decision()
        for (i in 0 until 32) {
            if (offset >= reader.size) break
            var relative = offset - windowOffset
            if (relative < 0 || relative > window.size - 16L) {
                val count = minOf(MAX_METADATA_BYTES.toLong(), reader.size - offset).toInt()
                require(count >= 8)
                window = reader.read(offset, count); windowOffset = offset; relative = 0
            }
            val box = box(window, relative.toInt(), window.size, reader.size - offset)
            if (box.type == "moov") {
                require(box.size <= MAX_METADATA_BYTES && box.size <= reader.size - offset)
                val bytes = if (relative + box.size <= window.size) window.copyOfRange(relative.toInt(), (relative + box.size).toInt())
                    else reader.read(offset, box.size.toInt())
                result = classify(bytes, reader.size)
                break
            }
            require(box.type != "moof") // Fragmented files keep the normal streaming policy.
            require(box.size <= reader.size - offset)
            offset += box.size
        }
        result
    } catch (error: Exception) { fallback(error) }

    private data class Box(val type: String, val start: Int, val header: Int, val size: Long) {
        val data: Int get() = start + header
        val end: Int get() { require(size <= Int.MAX_VALUE - start); return start + size.toInt() }
    }
    private fun type(bytes: ByteArray, at: Int): String {
        require(at >= 0 && at <= bytes.size - 4)
        return String(bytes, at, 4, Charsets.ISO_8859_1)
    }
    private fun u32(bytes: ByteArray, at: Int): Long {
        require(at >= 0 && at <= bytes.size - 4)
        return ((bytes[at].toLong() and 255) shl 24) or ((bytes[at + 1].toLong() and 255) shl 16) or
            ((bytes[at + 2].toLong() and 255) shl 8) or (bytes[at + 3].toLong() and 255)
    }
    private fun u64(bytes: ByteArray, at: Int): Long {
        require(at >= 0 && at <= bytes.size - 8)
        val high = u32(bytes, at); require(high <= Int.MAX_VALUE)
        return (high shl 32) or u32(bytes, at + 4)
    }
    private fun box(bytes: ByteArray, at: Int, limit: Int, remaining: Long = (limit - at).toLong()): Box {
        require(at >= 0 && limit <= bytes.size && at <= limit - 8)
        val size = u32(bytes, at)
        val header = if (size == 1L) 16 else 8
        require(at <= limit - header)
        val total = when (size) { 0L -> remaining; 1L -> u64(bytes, at + 8); else -> size }
        require(total >= header && total <= remaining)
        return Box(type(bytes, at + 4), at, header, total)
    }
    private fun children(bytes: ByteArray, parent: Box): List<Box> {
        val result = ArrayList<Box>(); var at = parent.data
        while (at < parent.end) {
            require(result.size < 256)
            val next = box(bytes, at, parent.end); result.add(next); at = next.end
        }
        require(at == parent.end)
        return result
    }
    private fun child(bytes: ByteArray, parent: Box, name: String): Box =
        children(bytes, parent).single { it.type == name }
    private data class Track(val kind: String, val offsets: LongArray, val sampleBytes: Long)
    private fun track(bytes: ByteArray, trak: Box): Track? {
        val mdia = child(bytes, trak, "mdia")
        val hdlr = child(bytes, mdia, "hdlr"); require(hdlr.size >= hdlr.header + 12)
        val kind = type(bytes, hdlr.data + 8)
        if (kind != "soun" && kind != "vide") return null
        val stbl = child(bytes, child(bytes, mdia, "minf"), "stbl")
        val tables = children(bytes, stbl)
        val co = tables.single { it.type == "stco" || it.type == "co64" }
        require(co.size >= co.header + 8)
        val count = u32(bytes, co.data + 4)
        val width = if (co.type == "co64") 8 else 4
        require(count in 1..262144 && count * width <= co.end - co.data - 8)
        val offsets = LongArray(count.toInt()) { i ->
            if (width == 8) u64(bytes, co.data + 8 + i * width) else u32(bytes, co.data + 8 + i * width)
        }
        for (i in 1 until offsets.size) require(offsets[i] > offsets[i - 1])
        val sz = tables.single { it.type == "stsz" }; require(sz.size >= sz.header + 12)
        val fixed = u32(bytes, sz.data + 4); val samples = u32(bytes, sz.data + 8)
        require(samples in 1..10000000)
        val sampleBytes = if (fixed > 0) Math.multiplyExact(fixed, samples) else {
            require(samples * 4 <= sz.end - sz.data - 12)
            var sum = 0L
            for (i in 0 until samples.toInt()) sum = Math.addExact(sum, u32(bytes, sz.data + 12 + i * 4))
            sum
        }
        return Track(kind, offsets, sampleBytes)
    }
    private fun classify(bytes: ByteArray, fileSize: Long): Decision {
        val moov = box(bytes, 0, bytes.size); require(moov.type == "moov" && moov.end == bytes.size)
        val boxes = children(bytes, moov)
        require(boxes.none { it.type == "mvex" })
        val tracks = boxes.filter { it.type == "trak" }.mapNotNull { track(bytes, it) }
        require(tracks.all { it.sampleBytes <= fileSize && it.offsets.all { offset -> offset in 1 until fileSize } })
        // Different audio/video selections must not inherit a guess about the first track.
        val audio = tracks.filter { it.kind == "soun" }.single()
        val video = tracks.filter { it.kind == "vide" }.single()
        require(audio.sampleBytes in MIN_AUDIO_BYTES..MAX_AUDIO_BYTES && audio.offsets.size >= 2)
        val videoStart = video.offsets.first()
        val prefixBytes = videoStart - audio.offsets.first()
        require(prefixBytes in MIN_AUDIO_BYTES..MAX_AUDIO_BYTES)
        require(prefixBytes <= audio.sampleBytes && prefixBytes >= audio.sampleBytes - 1024 * 1024)
        // Allow the final short audio chunk after video, as in the reported Resolve export.
        require(audio.offsets.count { it < videoStart } >= audio.offsets.size - 1)
        return Decision(true, prefixBytes, "leading_audio")
    }

    /** Optional compatibility probe. Unsupported Range, malformed metadata, cancellation or
     * its five-second/8-MiB budget simply leave MPV's existing policy in place. */
    fun inspectHttp(location: String, cancelled: () -> Boolean = { false }): Decision = try {
        val uri = URI(location)
        require(uri.scheme in setOf("http", "https") && uri.rawUserInfo == null)
        val deadline = System.nanoTime() + 5_000_000_000L
        val reader = object : Reader {
            override var size = Long.MAX_VALUE
            var readBytes = 0; var requests = 0
            fun remainingMs(): Int {
                require(!cancelled() && !Thread.currentThread().isInterrupted)
                return ((deadline - System.nanoTime()) / 1_000_000).toInt().also { require(it > 0) }
            }
            override fun read(offset: Long, length: Int): ByteArray {
                require(offset >= 0 && offset < size && length > 0 && ++requests <= 8)
                val count = minOf(length.toLong(), size - offset).toInt()
                require(count <= MAX_METADATA_BYTES && readBytes + count <= MAX_METADATA_BYTES + HEAD_BYTES)
                val connection = uri.toURL().openConnection() as HttpURLConnection
                try {
                    connection.connectTimeout = minOf(1500, remainingMs()); connection.readTimeout = remainingMs()
                    connection.instanceFollowRedirects = false; connection.useCaches = false
                    connection.setRequestProperty("Accept-Encoding", "identity")
                    connection.setRequestProperty("Range", "bytes=$offset-${offset + count - 1}")
                    require(connection.responseCode == 206)
                    val range = Regex("bytes ([0-9]+)-([0-9]+)/([0-9]+)").matchEntire(connection.getHeaderField("Content-Range").orEmpty())
                        ?: throw IOException("Range unavailable")
                    val first = range.groupValues[1].toLong(); val last = range.groupValues[2].toLong(); val total = range.groupValues[3].toLong()
                    require(first == offset && total > offset && last >= first && last < total && (size == Long.MAX_VALUE || size == total))
                    size = total
                    val wanted = minOf(count.toLong(), total - offset).toInt()
                    require(last - first + 1 >= wanted)
                    val result = ByteArray(wanted)
                    connection.inputStream.use { input ->
                        var at = 0
                        while (at < wanted) {
                            remainingMs()
                            val n = input.read(result, at, minOf(16384, wanted - at)); require(n > 0)
                            at += n; readBytes += n
                        }
                    }
                    return result
                } finally { connection.disconnect() }
            }
        }
        inspect(reader)
    } catch (error: Exception) { fallback(error) }
}
