package org.vrpassthroughplayer.plugin

import java.net.URI

/** A clear, single fMP4 live rendition. All remote references are checked before publication. */
internal class WebVideoLivePlaylist private constructor(
    val sequence: Long,
    val targetSeconds: Int,
    val initialization: URI,
    val segments: List<Segment>,
    private val lines: List<String>,
) {
    class Segment(val uri: URI, val durationSeconds: Double)

    fun localize(startIndex: Int = 0, endIndex: Int = segments.size, address: (URI, Boolean) -> String): ByteArray {
        require(startIndex in segments.indices)
        require(endIndex in (startIndex + 1)..segments.size)
        var segment = 0
        return lines.mapNotNull { line ->
            when {
                line.startsWith("#EXT-X-MAP:") -> "#EXT-X-MAP:URI=\"${address(initialization, true)}\""
                startIndex > 0 && line.startsWith("#EXT-X-MEDIA-SEQUENCE:") -> "#EXT-X-MEDIA-SEQUENCE:${sequence + startIndex}"
                (startIndex > 0 || endIndex < segments.size) && line.startsWith("#EXT-X-START:") -> null
                line.startsWith("#EXTINF:") && segment !in startIndex until endIndex -> null
                line.startsWith('#') -> line
                else -> {
                    val index = segment++
                    if (index !in startIndex until endIndex) null else address(segments[index].uri, false)
                }
            }
        }.joinToString("\n", postfix = "\n").toByteArray(Charsets.UTF_8)
    }

    companion object {
        const val MAX_BYTES = 64 * 1024
        private val map = Regex("#EXT-X-MAP:URI=\"([^\"]+)\"")
        private val start = Regex("#EXT-X-START:TIME-OFFSET=-?[0-9]{1,4}(?:\\.[0-9]{1,6})?(?:,PRECISE=(?:YES|NO))?")

        fun singleRendition(base: URI, bytes: ByteArray): URI? {
            require(bytes.size in 1..MAX_BYTES)
            val lines = bytes.toString(Charsets.UTF_8).removePrefix("\uFEFF").lineSequence()
                .map(String::trim).filter(String::isNotEmpty).toList()
            if (lines.none { it.startsWith("#EXT-X-STREAM-INF:") }) return null
            require(lines.firstOrNull() == "#EXTM3U" && lines.size <= 8)
            val media = lines.drop(1).filterNot { it.startsWith("#EXT-X-VERSION:") }
            require(media.size == 2 && media[0].startsWith("#EXT-X-STREAM-INF:") && !media[0].contains("URI=") && !media[1].startsWith('#'))
            return resource(base, media[1]).also { require(it.path.endsWith(".m3u8", true)) }
        }

        fun parse(base: URI, bytes: ByteArray): WebVideoLivePlaylist {
            require(bytes.size in 1..MAX_BYTES && base.scheme in setOf("https", "http"))
            val input = bytes.toString(Charsets.UTF_8).removePrefix("\uFEFF").lineSequence()
                .map(String::trim).filter(String::isNotEmpty).toList()
            require(input.firstOrNull() == "#EXTM3U" && input.size <= 256)

            var sequence = -1L
            var target = 0
            var initialization: URI? = null
            var pendingDuration: Double? = null
            val segments = ArrayList<Segment>()
            val lines = arrayListOf("#EXTM3U")
            for (line in input.drop(1)) {
                require(line.none { it < ' ' || it == '\u007f' })
                when {
                    line.startsWith("#EXT-X-MEDIA-SEQUENCE:") -> {
                        require(sequence == -1L)
                        sequence = line.substringAfter(':').toLong()
                        require(sequence in 0..Long.MAX_VALUE - 64)
                    }
                    line.startsWith("#EXT-X-TARGETDURATION:") -> {
                        require(target == 0)
                        target = line.substringAfter(':').toInt()
                        require(target in 1..30)
                    }
                    line.startsWith("#EXT-X-MAP:") -> {
                        require(initialization == null && segments.isEmpty() && pendingDuration == null)
                        initialization = resource(base, map.matchEntire(line)?.groupValues?.get(1) ?: error("Unsupported live init"))
                    }
                    line.startsWith("#EXTINF:") -> {
                        require(initialization != null && pendingDuration == null)
                        pendingDuration = line.substringAfter(':').substringBefore(',').toDouble()
                        require(pendingDuration > 0 && pendingDuration <= 30)
                        lines.add("#EXTINF:$pendingDuration,")
                        continue
                    }
                    line.startsWith("#EXT-X-VERSION:") -> require(line.substringAfter(':').toInt() in 6..10)
                    line.startsWith("#EXT-X-START:") -> require(start.matches(line))
                    line.startsWith("#EXT-BILI-AUX:") -> continue // Bilibili's auxiliary player data is not a media reference.
                    line.startsWith('#') -> error("Unsupported live playlist directive")
                    else -> {
                        val uri = resource(base, line)
                        require(uri.path.endsWith(".m4s", true) && segments.size < 32)
                        segments.add(Segment(uri, pendingDuration ?: error("Live segment has no duration")))
                        pendingDuration = null
                    }
                }
                lines.add(line)
            }
            return WebVideoLivePlaylist(sequence, target, requireNotNull(initialization), segments, lines).also {
                require(sequence >= 0 && target > 0 && segments.size >= 2 && pendingDuration == null &&
                    segments.all { Math.round(it.durationSeconds) <= target } && segments.map { it.uri }.distinct().size == segments.size)
            }
        }

        private fun resource(base: URI, value: String): URI {
            val uri = base.resolve(value)
            fun port(address: URI) = if (address.port != -1) address.port else if (address.scheme == "https") 443 else 80
            require(value.length <= 8192 && value.none { it <= ' ' || it == '\u007f' } && uri.scheme == base.scheme &&
                uri.host.equals(base.host, true) && port(uri) == port(base) && uri.rawUserInfo == null && uri.fragment == null)
            return uri
        }
    }
}
