package org.vrpassthroughplayer.plugin

/** Reuses the existing sparse MP4 Reader contract. Inspect metadata only, skipping
 * mdat by its validated box length; playback still uses the untouched source URL. */
internal object WebVideoMp4Header {
    // Ordinary long MP4s can have multi-megabyte sample tables. Keep the initial
    // payload prefix at 2 MiB; only sparse, validated metadata may use this cap.
    internal const val METADATA_LIMIT=8*1024*1024
    fun inspect(reader: Mp4InterleavePolicy.Reader, prefix: ByteArray): ByteArray {
        require(prefix.size >= 16 && String(prefix, 4, 4, Charsets.US_ASCII) == "ftyp")
        var offset = 0L
        var ftyp: ByteArray? = null
        var moov: ByteArray? = null
        var media = false
        var boxes = 0
        fun read(at: Long, length: Int): ByteArray {
            require(length > 0 && length <= METADATA_LIMIT && at >= 0 && length <= reader.size - at)
            return if (at <= prefix.size && length <= prefix.size - at) prefix.copyOfRange(at.toInt(), at.toInt() + length)
                else reader.read(at, length).also { require(it.size == length) }
        }
        fun uint(bytes: ByteArray, at: Int, count: Int): Long {
            var n = 0L
            repeat(count) { require(n <= Long.MAX_VALUE ushr 8); n = (n shl 8) or (bytes[at + it].toLong() and 255) }
            return n
        }
        while (offset < reader.size) {
            require(++boxes <= 64 && reader.size - offset >= 8)
            val header = read(offset, minOf(16L, reader.size - offset).toInt())
            val raw = uint(header, 0, 4)
            val headerSize = if (raw == 1L) 16 else 8
            val size = if (raw == 1L) { require(header.size >= 16); uint(header, 8, 8) }
                else if (raw == 0L) reader.size - offset else raw
            require(size >= headerSize && size <= reader.size - offset)
            when (String(header, 4, 4, Charsets.US_ASCII)) {
                "ftyp" -> { require(offset == 0L && ftyp == null && size <= 4096); ftyp = read(offset, size.toInt()) }
                "moov" -> { require(moov == null && size <= METADATA_LIMIT); moov = read(offset, size.toInt()) }
                "mdat" -> media = true
                "pssh", "moof" -> error("Protected or fragmented file is not a whole MP4 metadata probe")
            }
            offset += size
        }
        require(media && ftyp != null && moov != null)
        return ftyp + moov
    }
}
