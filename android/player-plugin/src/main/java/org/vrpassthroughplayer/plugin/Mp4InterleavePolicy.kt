package org.vrpassthroughplayer.plugin

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI

/** A bounded metadata check; never scans mdat, changes the file, or probes a decoder.
 * Existing leading-audio compatibility keeps its 128-MiB cap. Other time/physical
 * ordering mismatches instead retain bounded upstream windows and audio payload. */
internal object Mp4InterleavePolicy {
    const val MAX_AUDIO_BYTES = 128L * 1024 * 1024
    const val MAX_METADATA_BYTES = 8 * 1024 * 1024
    private const val HEAD_BYTES = 32 * 1024
    private const val MIN_AUDIO_BYTES = 32L * 1024 * 1024
    data class Decision(val sequential: Boolean = false, val leadingAudioBytes: Long = 0, val diagnostic: String = "default",
                        val regionCache: Boolean = false, val audioChunks: List<AudioReadSpan> = emptyList(),
                        val playbackLayout: Mp4PlaybackLayout? = null) {
        // Keep the previously validated small-audio cache path. Escalate only
        // when even the whole compressed track cannot fit its existing budget.
        val preferPlaybackView: Boolean get() = playbackLayout != null &&
            audioChunks.sumOf { it.end - it.start } > Mp4AudioPacketCache.DEFAULT_BUDGET_BYTES
    }
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
        var mediaStart = -1L; var mediaEnd = -1L; var mediaBoxes = 0
        var simpleTopLevel = true
        val ftyp = box(head, 0, head.size).let { head.copyOfRange(0, it.end) }
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
                if (result.regionCache && simpleTopLevel && mediaBoxes == 1 && offset + box.size == reader.size) {
                    val layout = runCatching { playbackLayout(bytes, ftyp, mediaStart, mediaEnd, reader.size) }.getOrNull()
                    result = result.copy(playbackLayout = layout)
                }
                break
            }
            if (box.type == "mdat") { mediaBoxes++; mediaStart = offset + box.header; mediaEnd = offset + box.size }
            if (box.type !in setOf("ftyp", "free", "wide", "mdat")) simpleTopLevel = false
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

    /** Tail-moov, self-contained single AV pair only. Every mdat byte must be
     * accounted for; unsupported tables/tracks keep the established cache path. */
    private fun playbackLayout(bytes: ByteArray, ftyp: ByteArray, mediaStart: Long, mediaEnd: Long, fileSize: Long): Mp4PlaybackLayout {
        val moov = box(bytes, 0, bytes.size)
        val traks = children(bytes, moov).filter { it.type == "trak" }; require(traks.size == 2)
        val tracks = traks.map { track(bytes, it) ?: error("Unsupported track") }
        require(tracks.count { it.kind == "vide" } == 1 && tracks.count { it.kind == "soun" } == 1)
        data class Part(val track: Int, val index: Int, val span: AudioReadSpan, val time: Double, val samples: Int)
        val parts = ArrayList<Part>()
        val replacements = HashMap<Int, ByteArray>()
        fun atom(type: String, payload: ByteArray): ByteArray = java.nio.ByteBuffer.allocate(payload.size + 8)
            .putInt(payload.size + 8).put(type.toByteArray(Charsets.US_ASCII)).put(payload).array()
        tracks.forEachIndexed { index, track ->
            val tables = children(bytes, track.stbl)
            // Unknown/auxiliary tables may contain absolute offsets. Keep their
            // original source rather than copying an address we cannot remap.
            require(tables.all { it.type in setOf("stsd", "stsc", "stsz", "stts", "ctts", "stss", "stco", "co64", "sdtp", "sgpd", "sbgp") })
            // AAC roll recovery describes sample counts, never file addresses.
            tables.filter { it.type == "sgpd" || it.type == "sbgp" }.forEach {
                require(type(bytes, it.data + 4) in setOf("roll", "prol"))
            }
            val sd = tables.single { it.type == "stsd" }
            require(u32(bytes, sd.data + 4) == 1L)
            val entry = box(bytes, sd.data + 8, sd.end)
            require(entry.end == sd.end && entry.type in if (track.kind == "vide") setOf("avc1", "avc3", "hvc1", "hev1") else setOf("mp4a"))
            require(entry.size >= entry.header + 8 && bytes[entry.data + 6] == 0.toByte() && bytes[entry.data + 7] == 1.toByte())
            val minf = child(bytes, track.mdia, "minf")
            val dref = child(bytes, child(bytes, minf, "dinf"), "dref")
            require(u32(bytes, dref.data + 4) == 1L)
            val reference = box(bytes, dref.data + 8, dref.end)
            require(reference.type == "url " && reference.end == dref.end && u32(bytes, reference.data) == 1L)
            val mdhd = child(bytes, track.mdia, "mdhd")
            val scale = u32(bytes, mdhd.data + if (bytes[mdhd.data].toInt() == 1) 20 else 12)
            children(bytes, traks[index]).singleOrNull { it.type == "edts" }?.let { edts ->
                val edit = child(bytes, edts, "elst"); val version = bytes[edit.data].toInt()
                require(version in 0..1 && u32(bytes, edit.data + 4) == 1L)
                val mediaTime = if (version == 0) u32(bytes, edit.data + 12) else u64(bytes, edit.data + 16)
                require(mediaTime <= scale / 2 && u32(bytes, edit.data + if (version == 0) 16 else 24) == 0x10000L)
            }
            val sc = tables.single { it.type == "stsc" }; val sz = tables.single { it.type == "stsz" }
            val ts = tables.single { it.type == "stts" }; val co = tables.single { it.type == "stco" || it.type == "co64" }
            val fixed = u32(bytes, sz.data + 4); val scRuns = u32(bytes, sc.data + 4).toInt()
            var run = 0; var timeRun = 0; var timeUsed = 0L; var sample = 0; var ticks = 0L; var groupIndex = 0
            val groups = ArrayList<Part>()
            for (chunk in track.offsets.indices) {
                while (run + 1 < scRuns && u32(bytes, sc.data + 8 + (run + 1) * 12) <= chunk + 1L) run++
                val count = u32(bytes, sc.data + 12 + run * 12).toInt()
                require(u32(bytes, sc.data + 16 + run * 12) == 1L)
                var source = track.offsets[chunk]; var groupStart = source; var groupTicks = ticks; var groupSamples = 0
                fun flush() {
                    if (groupSamples > 0) {
                        require(groups.size < 262144)
                        groups.add(Part(index, groupIndex++, AudioReadSpan(groupStart, source), groupTicks.toDouble() / scale, groupSamples))
                        groupStart = source; groupTicks = ticks; groupSamples = 0
                    }
                }
                repeat(count) {
                    val timing = ts.data + 8 + timeRun * 8
                    val duration = u32(bytes, timing + 4)
                    require(duration * 2 <= scale) // A single long sample cannot be subdivided losslessly.
                    if (groupSamples > 0 && (ticks - groupTicks + duration) * 2 > scale) flush()
                    val length = if (fixed > 0) fixed else u32(bytes, sz.data + 12 + sample * 4)
                    require(length > 0 && sample.toLong() < track.samples)
                    source = Math.addExact(source, length); ticks = Math.addExact(ticks, duration)
                    sample++; groupSamples++; timeUsed++
                    if (timeUsed == u32(bytes, timing)) { timeRun++; timeUsed = 0 }
                }
                flush()
                require(groups.size <= 262144)
            }
            require(sample.toLong() == track.samples)
            parts.addAll(groups)
            val runs = groups.indices.filter { it == 0 || groups[it].samples != groups[it - 1].samples }
            val newSc = java.nio.ByteBuffer.allocate(8 + runs.size * 12).putInt(0).putInt(runs.size)
            runs.forEach { newSc.putInt(it + 1).putInt(groups[it].samples).putInt(1) }
            replacements[sc.start] = atom("stsc", newSc.array())
            replacements[co.start] = atom("co64", java.nio.ByteBuffer.allocate(8 + groups.size * 8).putInt(0).putInt(groups.size).array())
        }
        val physical = parts.sortedBy { it.span.start }
        require(physical.first().span.start == mediaStart && physical.last().span.end == mediaEnd)
        for (i in 1 until physical.size) require(physical[i - 1].span.end == physical[i].span.start)
        fun rewrite(parent: Box): ByteArray {
            replacements[parent.start]?.let { return it }
            if (parent.type !in setOf("moov", "trak", "mdia", "minf", "stbl")) return bytes.copyOfRange(parent.start, parent.end)
            val payload = java.io.ByteArrayOutputStream()
            children(bytes, parent).forEach { payload.write(rewrite(it)) }
            return atom(parent.type, payload.toByteArray())
        }
        val patched = rewrite(moov)
        require(patched.size <= MAX_METADATA_BYTES)
        fun put(at: Int, value: Long, width: Int) {
            require(value >= 0 && (width == 8 || value <= 0xffffffffL))
            for (i in 0 until width) patched[at + i] = (value ushr ((width - 1 - i) * 8)).toByte()
        }
        val tables = children(patched, box(patched, 0, patched.size)).filter { it.type == "trak" }.map {
            child(patched, child(patched, child(patched, it, "mdia"), "minf"), "stbl")
        }.map { child(patched, it, "co64") }
        val ordered = parts.sortedWith(compareBy<Part> { it.time }.thenBy { it.track }.thenBy { it.index })
        var at = ftyp.size.toLong() + patched.size + 16
        val chunks = ordered.map { part ->
            val table = tables[part.track]; val width = if (table.type == "co64") 8 else 4
            put(table.data + 8 + part.index * width, at, width)
            Mp4PlaybackLayout.Chunk(at, part.span.start, part.span.end - part.span.start).also { at = Math.addExact(at, it.length) }
        }
        val mdat = java.nio.ByteBuffer.allocate(16).putInt(1).put("mdat".toByteArray(Charsets.US_ASCII))
            .putLong(mediaEnd - mediaStart + 16).array()
        return Mp4PlaybackLayout(fileSize, ftyp + patched + mdat, chunks,
            parts.filter { tracks[it.track].kind == "soun" }.map { it.span }.sortedBy { it.start })
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
    private data class Track(val kind: String, val offsets: LongArray, val sampleBytes: Long,
                             val samples: Long, val mdia: Box, val stbl: Box)
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
        return Track(kind, offsets, sampleBytes, samples, mdia, stbl)
    }
    /** Chunk decode boundaries, built from runs without expanding every sample.
     * This is only reached after the native seek-storm signal. */
    private fun chunkTimes(bytes: ByteArray, track: Track): DoubleArray {
        val mdhd = child(bytes, track.mdia, "mdhd")
        require(mdhd.size >= mdhd.header + 4)
        val version = bytes[mdhd.data].toInt(); require(version in 0..1)
        val scaleAt = mdhd.data + if (version == 1) 20 else 12
        require(scaleAt <= mdhd.end - 4)
        val scale = u32(bytes, scaleAt); require(scale > 0)
        val sc = child(bytes, track.stbl, "stsc")
        val ts = child(bytes, track.stbl, "stts")
        require(sc.size >= sc.header + 8 && ts.size >= ts.header + 8)
        val runs = u32(bytes, sc.data + 4).toInt()
        val times = u32(bytes, ts.data + 4).toInt()
        require(runs in 1..track.offsets.size && runs.toLong() * 12 == (sc.end - sc.data - 8).toLong())
        require(times in 1..1000000 && times.toLong() * 8 == (ts.end - ts.data - 8).toLong())
        require(u32(bytes, sc.data + 8) == 1L)
        for (i in 0 until runs) {
            val at = sc.data + 8 + i * 12
            require(u32(bytes, at) in 1..track.offsets.size.toLong() && u32(bytes, at + 4) > 0 && u32(bytes, at + 8) > 0)
            if (i > 0) require(u32(bytes, at) > u32(bytes, at - 12))
        }
        var sum = 0L
        for (i in 0 until times) {
            val at = ts.data + 8 + i * 8
            require(u32(bytes, at) > 0 && u32(bytes, at + 4) > 0)
            sum = Math.addExact(sum, u32(bytes, at))
        }
        require(sum == track.samples)
        var run = 0; var timeRun = 0; var used = 0L; var sample = 0L; var ticks = 0L
        val result = DoubleArray(track.offsets.size + 1)
        for (i in track.offsets.indices) {
            while (run + 1 < runs && u32(bytes, sc.data + 8 + (run + 1) * 12) <= i + 1L) run++
            result[i] = ticks.toDouble() / scale
            var remaining = u32(bytes, sc.data + 12 + run * 12)
            sample = Math.addExact(sample, remaining); require(sample <= track.samples)
            while (remaining > 0) {
                require(timeRun < times)
                val at = ts.data + 8 + timeRun * 8
                val take = minOf(remaining, u32(bytes, at) - used)
                ticks = Math.addExact(ticks, Math.multiplyExact(take, u32(bytes, at + 4)))
                used += take; remaining -= take
                if (used == u32(bytes, at)) { timeRun++; used = 0 }
            }
        }
        require(sample == track.samples)
        result[result.lastIndex] = ticks.toDouble() / scale
        return result
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
        val videoStart = video.offsets.first()
        val prefixBytes = videoStart - audio.offsets.first()
        // Preserve the previously validated leading-audio compatibility path.
        if (audio.sampleBytes in MIN_AUDIO_BYTES..MAX_AUDIO_BYTES && audio.offsets.size >= 2 &&
            prefixBytes in MIN_AUDIO_BYTES..MAX_AUDIO_BYTES && prefixBytes <= audio.sampleBytes &&
            prefixBytes >= audio.sampleBytes - 1024 * 1024 &&
            audio.offsets.count { it < videoStart } >= audio.offsets.size - 1)
            return Decision(true, prefixBytes, "leading_audio")
        val audioTimes = chunkTimes(bytes, audio); val videoTimes = chunkTimes(bytes, video)
        // Follow physical chunk order. A chunk ending >1 second ahead of the
        // other track forces lavf away from its physical-order preference.
        // No file/audio size, duration or minimum chunk-count eligibility gate.
        var a = 0; var v = 0; var audioEnd = 0.0; var videoEnd = 0.0
        while (a < audio.offsets.size && v < video.offsets.size) {
            if (audio.offsets[a] < video.offsets[v]) audioEnd = audioTimes[++a]
            else videoEnd = videoTimes[++v]
            if (kotlin.math.abs(audioEnd - videoEnd) > 1.0)
                return Decision(diagnostic = "noninterleaved_tracks", regionCache = true,
                    audioChunks = if (audioEnd - videoEnd > 1.0) chunkSpans(bytes, audio, fileSize) else emptyList())
        }
        return Decision()
    }

    /** Locate compressed payload, excluding the potentially huge video gaps
     * between audio chunks. The byte budget belongs to the cache, not eligibility. */
    private fun chunkSpans(bytes: ByteArray, track: Track, fileSize: Long): List<AudioReadSpan> {
        val sc = child(bytes, track.stbl, "stsc")
        val sz = child(bytes, track.stbl, "stsz")
        val runs = u32(bytes, sc.data + 4).toInt()
        val fixed = u32(bytes, sz.data + 4)
        var run = 0; var sample = 0L
        return track.offsets.mapIndexed { index, start ->
            while (run + 1 < runs && u32(bytes, sc.data + 8 + (run + 1) * 12) <= index + 1L) run++
            val count = u32(bytes, sc.data + 12 + run * 12)
            require(count <= track.samples - sample)
            val length = if (fixed > 0) Math.multiplyExact(fixed, count) else {
                var sum = 0L
                repeat(count.toInt()) { i -> sum = Math.addExact(sum, u32(bytes, sz.data + 12 + (sample.toInt() + i) * 4)) }
                sum
            }
            sample += count
            val end = Math.addExact(start, length)
            require(length > 0 && end <= fileSize && (index == track.offsets.lastIndex || end <= track.offsets[index + 1]))
            AudioReadSpan(start, end)
        }.also { require(sample == track.samples) }
    }

    /** Optional compatibility probe. The 5-second base adds time for a large index
     * (at 512 KiB/s), capped at 20 seconds and 8 MiB. Unsupported input falls back. */
    fun inspectHttp(location: String, cancelled: () -> Boolean = { false }): Decision = try {
        val uri = URI(location)
        require(uri.scheme in setOf("http", "https") && uri.rawUserInfo == null)
        val started = System.nanoTime()
        var deadline = started + 5_000_000_000L
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
                val metadataBytes = (readBytes.toLong() + count - HEAD_BYTES).coerceAtLeast(0)
                val budgetMs = minOf(20_000L, 5000L + (metadataBytes * 1000 + 524287) / 524288)
                deadline = started + budgetMs * 1_000_000L
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
