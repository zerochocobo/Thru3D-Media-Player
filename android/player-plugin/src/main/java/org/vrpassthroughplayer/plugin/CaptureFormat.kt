package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.io.BufferedInputStream
import java.util.zip.CRC32

/** Portable source layout, independent of history and per-file preference switches. */
internal object CaptureFormat {
    private val signature = byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)
    private val jpegKey = "thru3d_mode\u0000".toByteArray(Charsets.US_ASCII)
    fun clean(value: JSONObject, allowFlat: Boolean = false): JSONObject {
        val geometry = value.getInt("geometry")
        require(geometry in (if (allowFlat) 0..3 else 1..3) && value.getDouble("geometry") == geometry.toDouble() && value.optInt("version", 1) == 1)
        val fov = value.optInt("fisheye_fov", 180)
        require(fov in listOf(180, 190, 200, 220))
        for (field in listOf("stereo_sbs", "top_bottom", "stereo_half", "swap_eyes")) {
            require(!value.has(field) || value.get(field) is Boolean)
        }
        return JSONObject().put("version", 1).put("geometry", geometry)
            .put("stereo_sbs", value.optBoolean("stereo_sbs"))
            .put("top_bottom", value.optBoolean("top_bottom"))
            .put("stereo_half", value.optBoolean("stereo_half"))
            .put("swap_eyes", value.optBoolean("swap_eyes"))
            .put("fisheye_fov", fov)
    }
    /** Insert after IHDR; readers can inspect layout without scanning a large screenshot. */
    fun png(input: InputStream, output: OutputStream, mode: JSONObject): Long {
        val source = DataInputStream(input)
        val prefix = ByteArray(33); source.readFully(prefix)
        require(prefix.copyOfRange(0, 8).contentEquals(signature))
        val data = ("thru3d_mode\u0000" + clean(mode, allowFlat = true)).toByteArray(Charsets.ISO_8859_1)
        val kind = "tEXt".toByteArray(Charsets.US_ASCII)
        val crc = CRC32().apply { update(kind); update(data) }
        val target = DataOutputStream(output)
        target.write(prefix); target.writeInt(data.size); target.write(kind); target.write(data); target.writeInt(crc.value.toInt())
        return 33L + data.size + 12 + source.copyTo(target)
    }
    fun readPng(input: InputStream): JSONObject? = runCatching {
        val source = DataInputStream(input)
        val prefix = ByteArray(8); source.readFully(prefix)
        if (!prefix.contentEquals(signature)) return null
        var count = 8
        while (count < 65536) {
            val size = source.readInt()
            if (size !in 0..8192) return null
            val kind = ByteArray(4); source.readFully(kind)
            val data = ByteArray(size); source.readFully(data)
            val crc = source.readInt()
            if (String(kind, Charsets.US_ASCII) == "tEXt" && data.take(12).toByteArray().contentEquals("thru3d_mode\u0000".toByteArray())) {
                require(CRC32().apply { update(kind); update(data) }.value.toInt() == crc)
                return clean(JSONObject(String(data, 12, data.size - 12, Charsets.ISO_8859_1)), allowFlat = true)
            }
            if (String(kind, Charsets.US_ASCII) in listOf("IDAT", "IEND")) return null
            count += size + 12
        }
        null
    }.getOrNull()

    /** Insert a small APP15 segment as the encoder writes; no second image or temporary file. */
    fun jpeg(output: OutputStream, mode: JSONObject, encode: (OutputStream) -> Unit): Long {
        val data = jpegKey + clean(mode, allowFlat = true).toString().toByteArray(Charsets.UTF_8)
        val metadata = java.io.ByteArrayOutputStream().also { bytes ->
            DataOutputStream(bytes).apply {
                writeShort(0xffef); writeShort(data.size + 6); write(data)
                writeInt(CRC32().apply { update(data) }.value.toInt())
            }
        }.toByteArray()
        var prefix = 0
        var count = 0L
        val stream = object : OutputStream() {
            override fun write(value: Int) { write(byteArrayOf(value.toByte()), 0, 1) }
            override fun write(bytes: ByteArray, offset: Int, length: Int) {
                require(offset >= 0 && length >= 0 && offset <= bytes.size - length)
                var start = offset
                val end = offset + length
                while (prefix < 2 && start < end) {
                    require((bytes[start].toInt() and 255) == if (prefix == 0) 255 else 216)
                    output.write(bytes[start++].toInt()); count++; prefix++
                    if (prefix == 2) { output.write(metadata); count += metadata.size }
                }
                if (start < end) { output.write(bytes, start, end - start); count += end - start }
            }
            override fun flush() = output.flush()
        }
        encode(stream)
        require(prefix == 2) { "JPEG header missing" }
        stream.flush()
        return count
    }

    fun read(input: InputStream): JSONObject? {
        val source = BufferedInputStream(input)
        source.mark(8)
        val first = source.read(); val second = source.read()
        source.reset()
        return if (first == 255 && second == 216) readJpeg(source) else readPng(source)
    }

    private fun readJpeg(input: InputStream): JSONObject? = runCatching {
        val source = DataInputStream(input)
        if (source.readUnsignedShort() != 0xffd8) return null
        var count = 2
        while (count < 65536) {
            if (source.readUnsignedByte() != 255) return null
            var kind = source.readUnsignedByte(); count += 2
            while (kind == 255 && count < 65536) { kind = source.readUnsignedByte(); count++ }
            if (kind == 0xda || kind == 0xd9 || kind == 0) return null
            if (kind == 1 || kind in 0xd0..0xd7) continue
            val size = source.readUnsignedShort() - 2; count += 2
            if (size < 0 || count + size > 65536) return null
            val data = ByteArray(size); source.readFully(data); count += size
            if (kind == 0xef && size > jpegKey.size + 4 && data.copyOfRange(0, jpegKey.size).contentEquals(jpegKey)) {
                val payload = data.copyOfRange(0, size - 4)
                require(CRC32().apply { update(payload) }.value.toInt() ==
                    DataInputStream(data.copyOfRange(size - 4, size).inputStream()).readInt())
                return clean(JSONObject(String(payload, jpegKey.size, payload.size - jpegKey.size, Charsets.UTF_8)), allowFlat = true)
            }
        }
        null
    }.getOrNull()
}
