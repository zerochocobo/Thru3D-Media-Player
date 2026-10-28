package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.CRC32
import java.util.zip.Inflater
import kotlin.math.ceil
import kotlin.math.ln
import kotlin.math.sqrt

/** Bounded SV3D/Matroska reader. Geometry comes from the selected representation, never its title.
 * Format references: google/spatial-media Spherical Video V2; AndroidX ProjectionDecoder also
 * documents YouTube's legacy ytmp alias. This reader additionally validates CRC and all counts. */
internal object SphericalVideoMetadata {
    const val PREFIX_LIMIT = 2 * 1024 * 1024
    private const val INFLATE_LIMIT = 2 * 1024 * 1024
    private data class Box(val type: String, val from: Int, val end: Int)
    private class State {
        var stereo = 0
        var type = ""
        var payload = byteArrayOf()
        var pose = doubleArrayOf(0.0, 0.0, 0.0)
    }
    private fun uint(d: ByteArray, p: Int, bytes: Int = 4): Long {
        require(bytes in 1..8 && p >= 0 && p <= d.size - bytes)
        var n = 0L
        repeat(bytes) { require(n <= Long.MAX_VALUE ushr 8); n = (n shl 8) or (d[p + it].toLong() and 255) }
        return n
    }
    private fun boxes(d: ByteArray, from: Int, end: Int, prefix: Boolean = false): List<Box> {
        require(from in 0..end && end <= d.size)
        val result = ArrayList<Box>(); var p = from
        while (p + 8 <= end) {
            require(result.size < 4096)
            val size = uint(d, p); val header = if (size == 1L) 16 else 8
            val length = if (size == 1L) uint(d, p + 8, 8) else if (size == 0L) (end - p).toLong() else size
            require(length >= header)
            if (length > end - p) { require(prefix); break }
            result.add(Box(String(d, p + 4, 4, Charsets.US_ASCII), p + header, p + length.toInt()))
            p += length.toInt()
        }
        return result
    }
    /** True once the first [size] bytes hold every header [parse] reads, so a probe can stop
     * instead of downloading the whole bounded prefix. Unknown or malformed data reads on. */
    fun headerComplete(d: ByteArray, size: Int): Boolean = runCatching {
        require(size in 0..minOf(d.size, PREFIX_LIMIT))
        if (size >= 8 && String(d, 4, 4, Charsets.US_ASCII) == "ftyp") {
            var p = 0
            while (p + 8 <= size) {
                val raw = uint(d, p); val header = if (raw == 1L) 16 else 8
                if (raw == 0L || p + header > size) return false
                val length = if (raw == 1L) uint(d, p + 8, 8) else raw
                if (length < header) return true // Malformed; let parse() reject what it has.
                val type = String(d, p + 4, 4, Charsets.US_ASCII)
                // Fragmented MP4 always places moov before the first fragment.
                if (type == "moof") return true
                if (p + length > size) {
                    // moov after a large mdat lies outside the prefix anyway.
                    return type == "mdat" && p + length > PREFIX_LIMIT
                }
                if (type == "moov") return true
                p += length.toInt()
            }
            return false
        }
        if (size >= 4 && uint(d, 0) == 0x1a45dfa3L) {
            val ebml = vint(d, 0, true); val ebmlSize = vint(d, ebml.next, false)
            if (ebmlSize.next > size || ebmlSize.unknown) return false
            var p = ebmlSize.next + ebmlSize.value.toInt()
            if (p >= size) return false
            val segment = vint(d, p, true)
            if (segment.value != 0x18538067L) return true
            if (segment.next >= size) return false
            p = vint(d, segment.next, false).next
            while (p < size) {
                val id = vint(d, p, true); if (id.next >= size) return false
                val length = vint(d, id.next, false); if (length.next > size) return false
                if (id.value == 0x1f43b675L) return true // Tracks/projection precede the first Cluster.
                if (length.unknown || length.value > PREFIX_LIMIT) return true
                p = length.next + length.value.toInt()
            }
        }
        false
    }.getOrDefault(false)

    fun parse(bytes: ByteArray): JSONObject? {
        require(bytes.size <= PREFIX_LIMIT)
        val s = State()
        if (bytes.size >= 8 && String(bytes, 4, 4, Charsets.US_ASCII) == "ftyp") mp4(bytes, 0, bytes.size, s, 0)
        else if (bytes.size >= 4 && uint(bytes, 0) == 0x1a45dfa3L) webm(bytes, 0, bytes.size, s, 0)
        else return null
        if (s.type.isEmpty()) return null
        require(s.stereo in 0..4 && s.pose.all { it.isFinite() && kotlin.math.abs(it) <= 360 })
        val result = JSONObject().put("version", 1).put("source", "selected_stream_container")
            .put("kind", s.type).put("stereo_mode", s.stereo).put("pose", JSONArray(s.pose.toList()))
        if (s.type == "equirectangular") {
            require(s.payload.size >= 20 && uint(s.payload, 0) == 0L && s.stereo != 3)
            val b = (0..3).map { uint(s.payload, 4 + it * 4) / 4294967296.0 }
            require(b[0] + b[1] < 1 && b[2] + b[3] < 1)
            result.put("bounds", JSONArray(b)).put("geometry", if (1 - b[2] - b[3] <= .501) 1 else 3)
        } else if (s.type == "mesh") {
            val meshes = meshProjection(s.payload)
            require(s.stereo != 3 || meshes.length() == 2)
            var behind = false
            for (i in 0 until meshes.length()) {
                val v = meshes.getJSONObject(i).getJSONArray("vertices")
                for (j in 0 until v.length() step 5) {
                    val x = v.getDouble(j); val y = v.getDouble(j+1); val z = v.getDouble(j+2)
                    val r = sqrt(x*x+y*y+z*z)
                    require(r in 0.000001..10000.0)
                    if (z / r > .025) behind = true
                }
            }
            result.put("geometry", if (behind) 3 else 1).put("meshes", meshes)
        } else error("Unsupported spherical projection")
        return result
    }
    private fun mp4(d: ByteArray, start: Int, end: Int, s: State, depth: Int) {
        require(depth <= 12)
        for (box in boxes(d, start, end, depth == 0)) {
            when (box.type) {
                "moov", "trak", "mdia", "minf", "stbl", "sv3d", "proj" -> mp4(d, box.from, box.end, s, depth+1)
                "stsd" -> { require(box.from + 8 <= box.end); mp4(d, box.from+8, box.end, s, depth+1) }
                "avc1", "avc3", "hvc1", "hev1", "av01", "vp09" -> {
                    require(box.from + 78 <= box.end); mp4(d, box.from+78, box.end, s, depth+1)
                }
                "st3d" -> { require(box.end-box.from >= 5 && uint(d,box.from)==0L); s.stereo=d[box.from+4].toInt() and 255 }
                "prhd" -> { require(box.end-box.from >= 16 && uint(d,box.from)==0L)
                    s.pose=DoubleArray(3) { ByteBuffer.wrap(d,box.from+4+it*4,4).int / 65536.0 } }
                "equi", "mshp", "ytmp", "cbmp" -> {
                    require(s.type.isEmpty()) { "Multiple projection definitions" }
                    s.type = if (box.type=="equi") "equirectangular" else if (box.type=="cbmp") "cubemap" else "mesh"
                    s.payload=d.copyOfRange(box.from,box.end)
                }
            }
        }
    }
    private data class Vint(val value: Long, val next: Int, val unknown: Boolean)
    private fun vint(d: ByteArray, p: Int, id: Boolean): Vint {
        require(p in d.indices && d[p].toInt()!=0)
        val first=d[p].toInt() and 255
        val n=Integer.numberOfLeadingZeros(first)-24+1
        require(n in 1..(if(id) 4 else 8) && p+n<=d.size)
        var value=(if(id) first else first and (255 ushr n)).toLong()
        for(i in 1 until n) value=(value shl 8) or (d[p+i].toLong() and 255)
        return Vint(value,p+n,!id && value == ((1L shl (7*n))-1))
    }
    private fun webm(d: ByteArray, start: Int, end: Int, s: State, depth: Int) {
        require(depth<=8); var p=start; var count=0
        var projectionType: Int?=null; var privateData: ByteArray?=null
        while(p<end) {
            require(++count<=4096)
            val id=vint(d,p,true); val size=vint(d,id.next,false)
            val e=if(size.unknown || (id.value==0x18538067L && size.value>end-size.next)) end else {
                if(size.value>end-size.next) { require(depth<=1); break }; size.next+size.value.toInt()
            }
            require(e>=size.next && e<=end)
            val a=size.next; val length=e-a
            when(id.value) {
                0x18538067L,0x1654ae6bL,0xaeL,0xe0L,0x7670L -> webm(d,a,e,s,depth+1)
                0x53b8L -> s.stereo=when(uint(d,a,length).toInt()) { 0->0; 1->2; 3->1; 11->4; 15->3; else->error("Unsupported stereo mode") }
                0x7671L -> projectionType=uint(d,a,length).toInt()
                0x7672L -> privateData=d.copyOfRange(a,e)
                0x7673L,0x7674L,0x7675L -> {
                    require(length==4 || length==8)
                    val b=ByteBuffer.wrap(d,a,length).order(ByteOrder.BIG_ENDIAN)
                    s.pose[(id.value-0x7673).toInt()]=if(length==4) b.float.toDouble() else b.double
                }
            }
            p=e
        }
        projectionType?.let {
            require(s.type.isEmpty())
            when(it) {
                0 -> Unit
                1 -> { s.type="equirectangular"; s.payload=privateData ?: ByteArray(20) }
                3 -> { s.type="mesh"; s.payload=privateData ?: error("Missing projection mesh") }
                else -> error("Unsupported spherical projection")
            }
        }
    }
    private class Bits(val data: ByteArray, var bit: Int) {
        fun read(n: Int): Long { require(n in 1..32 && bit.toLong()+n<=data.size.toLong()*8); var v=0L
            repeat(n) { v=(v shl 1) or ((data[bit/8].toInt() ushr (7-bit%8)) and 1).toLong(); bit++ }; return v }
        fun align() { bit=(bit+7) and -8 }
    }
    private fun meshProjection(d: ByteArray): JSONArray {
        require(d.size>=12 && uint(d,0)==0L)
        require(CRC32().apply { update(d,8,d.size-8) }.value==uint(d,4)) { "Projection CRC mismatch" }
        val encoding=String(d,8,4,Charsets.US_ASCII)
        val raw=if(encoding=="raw ") d.copyOfRange(12,d.size) else {
            require(encoding=="dfl8")
            val inflater=Inflater(true)
            try {
                inflater.setInput(d,12,d.size-12)
                val buffer=ByteArray(INFLATE_LIMIT+1); var size=0
                while(!inflater.finished()) { val n=inflater.inflate(buffer,size,buffer.size-size); require(n>0); size+=n; require(size<=INFLATE_LIMIT) }
                require(inflater.remaining==0); buffer.copyOf(size)
            } finally { inflater.end() }
        }
        val meshes=JSONArray()
        for(box in boxes(raw,0,raw.size)) if(box.type=="mesh") {
            require(meshes.length()<2)
            val b=Bits(raw.copyOfRange(box.from,box.end),0)
            val count=b.read(32).toInt(); require(count in 1..10000)
            val coords=FloatArray(count) { Float.fromBits(b.read(32).toInt()).also { require(it.isFinite()) } }
            val vertices=b.read(32).toInt(); require(vertices in 1..32000)
            val width=ceil(ln(count*2.0)/ln(2.0)).toInt()
            val previous=IntArray(5); val values=JSONArray()
            repeat(vertices) { repeat(5) { c ->
                val v=b.read(width).toInt(); previous[c]+=(v ushr 1) xor -(v and 1)
                require(previous[c] in coords.indices); values.put(coords[previous[c]].toDouble())
            } }
            b.align(); val groups=b.read(32).toInt(); require(groups in 1..32)
            val indices=JSONArray(); val iw=ceil(ln(vertices*2.0)/ln(2.0)).toInt()
            repeat(groups) {
                require(b.read(8)==0L); val mode=b.read(8).toInt(); require(mode in 0..2)
                val n=b.read(32).toInt(); require(n in 3..128000)
                val list=IntArray(n); var at=0
                repeat(n) { j -> val v=b.read(iw).toInt(); at+=(v ushr 1) xor -(v and 1); require(at in 0 until vertices); list[j]=at }
                fun triangle(a:Int,c:Int,e:Int) { if(a!=c && c!=e && a!=e) { indices.put(a).put(c).put(e); require(indices.length()<=384000) } }
                when(mode) {
                    0 -> { require(n%3==0); for(j in 0 until n step 3) triangle(list[j],list[j+1],list[j+2]) }
                    1 -> for(j in 2 until n) if(j%2==0) triangle(list[j-2],list[j-1],list[j]) else triangle(list[j-1],list[j-2],list[j])
                    2 -> for(j in 2 until n) triangle(list[0],list[j-1],list[j])
                }
                b.align()
            }
            require(indices.length()>0)
            meshes.put(JSONObject().put("vertices",values).put("indices",indices))
        }
        require(meshes.length() in 1..2)
        return meshes
    }
}
