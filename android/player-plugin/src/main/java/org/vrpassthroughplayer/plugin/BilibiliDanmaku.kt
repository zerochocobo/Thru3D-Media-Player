package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Future
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

internal class BilibiliDanmaku : AutoCloseable {
    private val worker = ThreadPoolExecutor(1, 1, 0L, TimeUnit.SECONDS,
        ArrayBlockingQueue(1), { task -> Thread(task, "bilibili-danmaku") })
    private var serial = 0
    private var request = 0
    private var work: Future<*>? = null
    private var result = ""

    @Synchronized fun fetch(cid: String, segment: Int): Int {
        if (!cid.matches(Regex("[1-9][0-9]{0,19}")) || segment !in 1..240 || worker.isShutdown) return 0
        cancel(request)
        val id = ++serial
        request = id
        work = worker.submit {
            val reply = runCatching {
                val items = JSONArray()
                for (comment in decode(download(cid, segment), segment)) {
                    items.put(JSONArray().put(comment.time).put(comment.text).put(comment.color))
                }
                JSONObject().put("items", items).toString()
            }.getOrElse { """{"unavailable":true}""" }
            synchronized(this) { if (request == id) result = reply }
        }
        return id
    }

    @Synchronized fun poll(id: Int): String {
        if (id != request || result.isEmpty()) return ""
        val reply = result
        request = 0
        work = null
        result = ""
        return reply
    }

    @Synchronized fun cancel(id: Int) {
        if (id != request || id == 0) return
        request = 0
        result = ""
        work?.cancel(true)
        work = null
        worker.purge()
    }

    @Synchronized override fun close() {
        cancel(request)
        worker.shutdownNow()
    }

    private fun download(cid: String, segment: Int): ByteArray {
        val url = URL("https://api.bilibili.com/x/v2/dm/web/seg.so?type=1&oid=$cid&segment_index=$segment")
        val connection = url.openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 4000
            connection.readTimeout = 4000
            connection.setRequestProperty("Accept", "application/octet-stream")
            require(connection.responseCode == HttpURLConnection.HTTP_OK)
            require(connection.contentType?.substringBefore(';') == "application/octet-stream")
            require(connection.contentLength <= MAX_RESPONSE)
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(8)
            return connection.inputStream.use { input ->
                val bytes = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    check(!Thread.currentThread().isInterrupted && System.nanoTime() < deadline)
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(bytes.size() + count <= MAX_RESPONSE)
                    bytes.write(buffer, 0, count)
                }
                bytes.toByteArray()
            }
        } finally {
            connection.disconnect()
        }
    }

    internal data class Comment(val time: Int, val text: String, val color: Int, val id: Long)

    companion object {
        private const val MAX_RESPONSE = 2 * 1024 * 1024
        private const val SEGMENT_MS = 360_000
        private const val MAX_COMMENTS = 12_000
        private val controls = Regex("[\\p{Cc}\\u202A-\\u202E\\u2066-\\u2069]")

        internal fun decode(bytes: ByteArray, segment: Int): List<Comment> {
            val start = (segment - 1) * SEGMENT_MS
            val reader = Reader(bytes, 0, bytes.size)
            val items = ArrayList<Comment>()
            val ids = HashSet<Long>()
            while (!reader.done()) {
                val tag = reader.tag()
                if (tag == 10) {
                    val comment = comment(reader.message()) ?: continue
                    if (comment.time in start until start + SEGMENT_MS &&
                        (comment.id == 0L || ids.add(comment.id))) items.add(comment)
                } else if (tag == 16) {
                    if (reader.varint() != 0L) return emptyList()
                } else reader.skip(tag)
            }
            items.sortBy { it.time }
            // Godot lays out every comment in lanes and drops what does not fit, as the
            // website does. Only an absurd segment is cut, evenly so no span goes empty.
            if (items.size <= MAX_COMMENTS) return items
            return List(MAX_COMMENTS) { items[(it.toLong() * items.size / MAX_COMMENTS).toInt()] }
        }

        private fun comment(reader: Reader): Comment? {
            var time = 0L
            var mode = 0L
            var pool = 0L
            var color = 0 // Protobuf omits the field when the posted RGB value is black.
            var id = 0L
            var text = ""
            while (!reader.done()) {
                when (val tag = reader.tag()) {
                    8 -> id = reader.varint()
                    16 -> time = reader.varint()
                    24 -> mode = reader.varint()
                    40 -> color = (reader.varint() and 0xffffff).toInt()
                    58 -> text = reader.text()
                    88 -> pool = reader.varint()
                    else -> reader.skip(tag)
                }
            }
            if (mode !in 1L..6L || pool != 0L || time !in 0..Int.MAX_VALUE.toLong()) return null
            text = controls.replace(text, " ").trim()
            if (text.isEmpty()) return null
            val end = text.offsetByCodePoints(0, minOf(80, text.codePointCount(0, text.length)))
            return Comment(time.toInt(), text.substring(0, end), color, id)
        }
    }

    /** The two messages use varints and length-delimited fields. Skip other protobuf fields. */
    private class Reader(private val bytes: ByteArray, private var at: Int, private val end: Int) {
        fun done(): Boolean = at == end

        fun tag(): Int {
            val value = varint()
            require(value in 8..Int.MAX_VALUE.toLong())
            return value.toInt()
        }

        fun varint(): Long {
            var value = 0L
            for (shift in 0..63 step 7) {
                require(at < end)
                val byte = bytes[at++].toInt() and 255
                require(shift < 63 || byte <= 1)
                value = value or ((byte and 127).toLong() shl shift)
                if (byte < 128) return value
            }
            error("Invalid protobuf varint")
        }

        fun message(): Reader {
            val length = varint()
            val start = at
            advance(length)
            return Reader(bytes, start, at)
        }

        fun text(): String {
            val length = varint()
            val start = at
            advance(length)
            return if (length <= 1024) bytes.decodeToString(start, at) else ""
        }

        fun skip(tag: Int) {
            when (tag and 7) {
                0 -> varint()
                1 -> advance(8)
                2 -> advance(varint())
                5 -> advance(4)
                else -> error("Unsupported protobuf wire type")
            }
        }

        private fun advance(length: Long) {
            require(length in 0..(end - at).toLong())
            at += length.toInt()
        }
    }
}
