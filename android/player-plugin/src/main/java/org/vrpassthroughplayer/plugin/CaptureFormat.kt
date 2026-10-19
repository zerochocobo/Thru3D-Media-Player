package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.util.zip.CRC32

/** Portable source layout, independent of history and per-file preference switches. */
internal object CaptureFormat {
    private val signature = byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)
    fun clean(value: JSONObject): JSONObject {
        val geometry = value.getInt("geometry")
        require(geometry in 1..3 && value.getDouble("geometry") == geometry.toDouble() && value.optInt("version", 1) == 1)
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
    fun png(input: InputStream, output: OutputStream, mode: JSONObject) {
        val source = DataInputStream(input)
        val prefix = ByteArray(33); source.readFully(prefix)
        require(prefix.copyOfRange(0, 8).contentEquals(signature))
        val data = ("thru3d_mode\u0000" + clean(mode)).toByteArray(Charsets.ISO_8859_1)
        val kind = "tEXt".toByteArray(Charsets.US_ASCII)
        val crc = CRC32().apply { update(kind); update(data) }
        val target = DataOutputStream(output)
        target.write(prefix); target.writeInt(data.size); target.write(kind); target.write(data); target.writeInt(crc.value.toInt())
        source.copyTo(target)
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
                return clean(JSONObject(String(data, 12, data.size - 12, Charsets.ISO_8859_1)))
            }
            if (String(kind, Charsets.US_ASCII) in listOf("IDAT", "IEND")) return null
            count += size + 12
        }
        null
    }.getOrNull()
}
