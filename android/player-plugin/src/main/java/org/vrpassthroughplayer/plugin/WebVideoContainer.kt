package org.vrpassthroughplayer.plugin

/** Bounded container header inspection for observed resources. A MIME type alone does not
 * prove a whole video or its audio; MSE init/segment responses must not be played as movies. */
internal object WebVideoContainer {
    class Info(val video: String, val audio: String, val width: Int, val height: Int, val duration: Double)
    private class Box(val type: String, val from: Int, val end: Int)
    private fun uint(d: ByteArray, p: Int, n: Int = 4): Long {
        require(n in 1..8 && p >= 0 && p <= d.size - n)
        var value = 0L
        repeat(n) { require(value <= Long.MAX_VALUE ushr 8); value = (value shl 8) or (d[p + it].toLong() and 255) }
        return value
    }
    private fun boxes(d: ByteArray, from: Int, end: Int, prefix: Boolean = false): List<Box> {
        val result = ArrayList<Box>(); var p = from
        while (p + 8 <= end) {
            require(result.size < 4096)
            val raw = uint(d, p); val header = if (raw == 1L) 16 else 8
            val length = if (raw == 1L) uint(d, p + 8, 8) else if (raw == 0L) (end - p).toLong() else raw
            require(length >= header)
            if (length > end - p) { require(prefix); break }
            result.add(Box(String(d, p + 4, 4, Charsets.US_ASCII), p + header, p + length.toInt()))
            p += length.toInt()
        }
        return result
    }
    fun parse(d: ByteArray): Info? = runCatching {
        if (d.size >= 8 && String(d, 4, 4, Charsets.US_ASCII) == "ftyp") mp4(d)
        else if (d.size >= 4 && uint(d, 0) == 0x1a45dfa3L) webm(d) else null
    }.getOrNull()

    /** A complete, single-packet PMT is enough to identify muxed TS. Split/malformed PSI
     * simply declines discovery; no elementary-stream payload is decoded here. */
    fun transportStream(d: ByteArray): Info? = runCatching {
        require(d.size >= 188 * 3 && d[0] == 0x47.toByte() && d[188] == 0x47.toByte())
        for (p in 0 until minOf(d.size - 187, 188 * 512) step 188) {
            if (d[p] != 0x47.toByte() || d[p + 1].toInt() and 0x40 == 0) continue
            val control = (d[p + 3].toInt() ushr 4) and 3
            if (control !in 1..3 || control == 2) continue
            var start = p + 4 + if (control == 3) (d[p + 4].toInt() and 255) + 1 else 0
            if (start >= p + 188) continue
            start += (d[start].toInt() and 255) + 1
            if (start + 12 >= p + 188 || d[start] != 2.toByte()) continue
            val length = ((d[start + 1].toInt() and 15) shl 8) or (d[start + 2].toInt() and 255)
            val end = start + 3 + length - 4
            if (end > p + 188) continue
            val descriptors = ((d[start + 10].toInt() and 15) shl 8) or (d[start + 11].toInt() and 255)
            var cursor = start + 12 + descriptors; var video = "none"; var audio = "none"
            while (cursor + 5 <= end) {
                when (d[cursor].toInt() and 255) { 0x1b -> video = "avc1"; 0x24 -> video = "hevc"; 0x0f, 0x11 -> audio = "mp4a.40.2"; 0x03, 0x04 -> audio = "mp3" }
                cursor += 5 + (((d[cursor + 3].toInt() and 15) shl 8) or (d[cursor + 4].toInt() and 255))
            }
            if (video != "none" || audio != "none") return Info(video, audio, 0, 0, 0.0)
        }
        null
    }.getOrNull()

    private fun mp4(d: ByteArray): Info {
        val top = boxes(d, 0, d.size, true)
        require(top.none { it.type == "pssh" })
        val moov = top.single { it.type == "moov" }
        val children = boxes(d, moov.from, moov.end)
        require(children.none { it.type == "pssh" })
        var video = "none"; var audio = "none"; var width = 0; var height = 0; var duration = 0.0
        for (trak in children.filter { it.type == "trak" }) {
            val mdia = boxes(d, trak.from, trak.end).single { it.type == "mdia" }
            val m = boxes(d, mdia.from, mdia.end)
            val hdlr = m.single { it.type == "hdlr" }
            require(hdlr.end - hdlr.from >= 12)
            val type = String(d, hdlr.from + 8, 4, Charsets.US_ASCII)
            if (type !in setOf("vide", "soun")) continue
            val mdhd = m.single { it.type == "mdhd" }; val version = uint(d, mdhd.from, 1).toInt()
            require(version in 0..1)
            val scaleAt = mdhd.from + if (version == 1) 20 else 12
            val scale = uint(d, scaleAt); val length = uint(d, scaleAt + 4, if (version == 1) 8 else 4)
            if (scale > 0 && length > 0 && length != 0xffffffffL) duration = maxOf(duration, length.toDouble() / scale)
            val minf = m.single { it.type == "minf" }
            val stbl = boxes(d, minf.from, minf.end).single { it.type == "stbl" }
            val stsd = boxes(d, stbl.from, stbl.end).single { it.type == "stsd" }
            val sample = boxes(d, stsd.from + 8, stsd.end).single()
            require(sample.type !in setOf("encv", "enca"))
            if (type == "vide") {
                require(video == "none" && sample.end - sample.from >= 78)
                width = uint(d, sample.from + 24, 2).toInt(); height = uint(d, sample.from + 26, 2).toInt()
                val config = boxes(d, sample.from + 78, sample.end)
                require(config.none { it.type == "sinf" })
                for (colour in config.filter { it.type == "colr" }) {
                    require(colour.end - colour.from >= 10 && String(d, colour.from, 4, Charsets.US_ASCII) in setOf("nclx", "nclc"))
                    require(uint(d, colour.from + 6, 2) in setOf(1L, 2L, 6L))
                }
                video = when (sample.type) {
                    "avc1", "avc3" -> {
                        val avc = config.single { it.type == "avcC" }; require(avc.end - avc.from >= 4)
                        "avc1." + (1..3).joinToString("") { "%02x".format(d[avc.from + it].toInt() and 255) }
                    }
                    "vp09" -> {
                        val vp = config.single { it.type == "vpcC" }; require(vp.end - vp.from >= 7 && uint(d, vp.from + 4, 1) == 0L && uint(d, vp.from + 6, 1) shr 4 == 8L)
                        "vp09.00"
                    }
                    "hvc1", "hev1" -> {
                        val hevc = config.single { it.type == "hvcC" }
                        require(hevc.end - hevc.from >= 23 && uint(d, hevc.from + 1, 1) and 31 == 1L &&
                            uint(d, hevc.from + 17, 1) and 7 == 0L && uint(d, hevc.from + 18, 1) and 7 == 0L)
                        sample.type
                    }
                    // Unverified profiles/bit depth must not bypass existing SDR selection.
                    else -> error("Unverified video profile")
                }
            } else { require(audio == "none"); audio = when (sample.type) { "mp4a" -> "mp4a.40.2"; "Opus" -> "opus"; else -> error("Unverified audio codec") } }
        }
        // SegmentBase files commonly leave mdhd.duration at zero and describe their full
        // timeline in sidx. Standalone init segments have neither duration nor references.
        if (duration == 0.0) top.firstOrNull { it.type == "sidx" }?.let { sidx ->
            val version = uint(d, sidx.from, 1); require(version in 0..1)
            val scale = uint(d, sidx.from + 8); require(scale > 0)
            val countAt = sidx.from + if (version == 0L) 22 else 30
            val count = uint(d, countAt, 2).toInt(); require(count in 1..4096 && countAt + 2 + count * 12 <= sidx.end)
            var ticks = 0L
            repeat(count) { i ->
                val p = countAt + 2 + i * 12
                require(uint(d, p) and 0x80000000L == 0L)
                ticks += uint(d, p + 4)
            }
            duration = ticks.toDouble() / scale
        }
        require(video != "none" || audio != "none")
        return Info(video, audio, width, height, duration)
    }

    private class Element(val id: Long, val from: Int, val end: Int)
    private fun vint(d: ByteArray, p: Int, id: Boolean): Pair<Long, Int> {
        val first = uint(d, p, 1).toInt(); require(first != 0)
        val n = Integer.numberOfLeadingZeros(first) - 24 + 1; require(n <= if (id) 4 else 8)
        var value = (if (id) first else first and (255 ushr n)).toLong()
        for (i in 1 until n) value = (value shl 8) or uint(d, p + i, 1)
        return (if (!id && value == (1L shl (7 * n)) - 1) -1 else value) to p + n
    }
    private fun elements(d: ByteArray, from: Int, end: Int, prefix: Boolean = false): List<Element> {
        val result = ArrayList<Element>(); var p = from
        while (p < end) {
            require(result.size < 4096)
            val (id, next) = vint(d, p, true); val (size, a) = vint(d, next, false)
            if (id == 0x1f43b675L) break // First Cluster: never inspect payload as metadata.
            val e = if (id == 0x18538067L && (size < 0 || size > end - a)) end else {
                if (size > end - a) { require(prefix); break }
                require(size >= 0); a + size.toInt()
            }
            result.add(Element(id, a, e)); p = e
        }
        return result
    }
    private fun webm(d: ByteArray): Info {
        val segment = elements(d, 0, d.size, true).single { it.id == 0x18538067L }
        val children = elements(d, segment.from, segment.end, true)
        val tracks = children.single { it.id == 0x1654ae6bL }
        var video = "none"; var audio = "none"; var width = 0; var height = 0; var duration = 0.0
        children.firstOrNull { it.id == 0x1549a966L }?.let { info ->
            val fields = elements(d, info.from, info.end)
            val scale = fields.firstOrNull { it.id == 0x2ad7b1L }?.let { uint(d, it.from, it.end - it.from) } ?: 1000000
            fields.firstOrNull { it.id == 0x4489L }?.let {
                val b = java.nio.ByteBuffer.wrap(d, it.from, it.end - it.from)
                val value = when (it.end - it.from) { 4 -> b.float.toDouble(); 8 -> b.double; else -> error("Invalid duration") }
                duration = value * scale / 1e9
            }
        }
        for (entry in elements(d, tracks.from, tracks.end).filter { it.id == 0xaeL }) {
            val fields = elements(d, entry.from, entry.end)
            require(fields.none { it.id == 0x6d80L }) // ContentEncodings, including encryption.
            val codec = fields.single { it.id == 0x86L }.let { String(d, it.from, it.end - it.from, Charsets.US_ASCII) }
            when (codec) {
                "V_VP8", "V_VP9" -> {
                    require(video == "none"); video = if (codec == "V_VP9") "vp9" else "vp8"
                    val v = fields.single { it.id == 0xe0L }; val dimensions = elements(d, v.from, v.end)
                    // Explicit non-SDR metadata isn't eligible for this conservative path.
                    dimensions.firstOrNull { it.id == 0x55b0L }?.let { colour ->
                        for (field in elements(d, colour.from, colour.end)) {
                            if (field.id == 0x55b2L) require(uint(d, field.from, field.end - field.from) == 8L)
                            if (field.id == 0x55baL) require(uint(d, field.from, field.end - field.from) in setOf(1L, 2L, 6L))
                        }
                    }
                    width = dimensions.single { it.id == 0xb0L }.let { uint(d, it.from, it.end - it.from).toInt() }
                    height = dimensions.single { it.id == 0xbaL }.let { uint(d, it.from, it.end - it.from).toInt() }
                }
                "A_OPUS", "A_VORBIS" -> { require(audio == "none"); audio = if (codec == "A_OPUS") "opus" else "vorbis" }
                else -> error("Unverified WebM codec")
            }
        }
        require(duration.isFinite() && duration >= 0 && (video != "none" || audio != "none"))
        return Info(video, audio, width, height, duration)
    }
}
