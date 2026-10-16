package org.vrpassthroughplayer.plugin

import java.io.File
import java.io.RandomAccessFile
import kotlin.math.abs
import kotlin.math.atan

/** Bounded HEIF metadata only. 'ster' IDs identify eyes; primary/thumbnail/gain-map order does not. */
internal data class HeifPhotoInfo(
    val primary: Int, val primaryOffset: Long, val idBytes: Int,
    val left: Int, val right: Int?, val width: Int, val height: Int,
    val hiddenFlagOffsets: Map<Int, Long>, val disparity: Double,
    val horizontalFovDegrees: Double? = null,
) {
    val stereo get() = right != null
    val packedWidth get() = width * if (stereo) 2 else 1

    /** Only a private decode copy is modified, never the user's original. */
    fun selectPrimary(copy: File, item: Int) {
        require(item == left || item == right) { "PHOTO_DECODE_FAILED" }
        RandomAccessFile(copy, "rw").use { f ->
            normalizeAndroidBrands(f)
            f.seek(primaryOffset)
            if (idBytes == 2) { require(item in 1..65535); f.writeShort(item) } else f.writeInt(item)
            hiddenFlagOffsets[item]?.let { offset ->
                f.seek(offset); val flags = f.readUnsignedByte()
                f.seek(offset); f.writeByte(flags and 0xfe)
            }
        }
    }

    companion object {
        private const val MAX_META = 4 * 1024 * 1024

        /** Android's extractor recognizes mif1+heic but rejects Apple's 10-bit heix brand.
         * This affects only the private decode copy; dimensions, bit depth, item payloads,
         * codec configuration and spatial metadata remain intact. */
        private fun normalizeAndroidBrands(f: RandomAccessFile) {
            var at = 0L; var count = 0
            while (at + 8 <= f.length() && ++count <= 4096) {
                f.seek(at)
                var size = f.readInt().toLong() and 0xffffffffL
                val type = f.readInt()
                var header = 8
                if (size == 1L) { size = f.readLong(); header = 16 }
                if (size == 0L) size = f.length() - at
                require(size >= header && size <= f.length() - at) { "PHOTO_DECODE_FAILED" }
                if (type == 0x66747970) { // ftyp
                    require(size in (header + 8).toLong()..4096L) { "PHOTO_DECODE_FAILED" }
                    fun alias(position: Long) {
                        f.seek(position)
                        if (f.readInt() == 0x68656978) { f.seek(position); f.writeInt(0x68656963) } // heix -> heic
                    }
                    alias(at + header)
                    var position = at + header + 8 // skip the minor-version field
                    while (position + 4 <= at + size) { alias(position); position += 4 }
                    return
                }
                at += size
            }
            error("PHOTO_DECODE_FAILED")
        }
        private val brands = setOf("heic", "heix", "hevc", "hevx", "heim", "heis")
        private val imageTypes = setOf("hvc1", "hev1", "grid", "jpeg")
        // Apple's spatial disparity property, signed fraction of image width x 10000.
        private val disparityUuid = "de22508536cb436587432f8705e7c78a"
        // Apple's UUID alias of the HEIF CameraIntrinsicMatrixProperty (cmin).
        private val intrinsicsUuid = "22cc04c7d6d94e079d904eb6ecbaf3a3"
        private data class Box(val start: Int, val body: Int, val end: Int, val type: String)
        private data class Intrinsics(val fx: Double, val fy: Double?, val cx: Double, val cy: Double)
        private data class Property(val width: Int = 0, val height: Int = 0, val rotate: Boolean = false, val disparity: Double? = null,
                                    val crop: Pair<Int,Int>? = null, val centeredCrop: Boolean = true, val intrinsics: Intrinsics? = null,
                                    val hasIntrinsics: Boolean = false)

        private fun intrinsics(b: ByteArray, start: Int, end: Int): Intrinsics? {
            if (end - start < 16 || b[start].toInt() != 0) return null
            val flags = u32(b, start).toInt() and 0xffffff
            val anisotropic = flags and 1 != 0
            if (flags and 0x1f1f01.inv() != 0 || end - start != if (anisotropic) 24 else 16) return null
            val denominator = (1L shl ((flags ushr 8) and 31)).toDouble()
            fun number(at: Int) = u32(b, at).toInt().toDouble() / denominator
            val fx = number(start + 4); val cx = number(start + 8); val cy = number(start + 12)
            val fy = if (anisotropic) number(start + 16) else null
            // This action matches a symmetric rectilinear view, not an off-axis camera.
            if (fx <= 0 || (fy != null && fy <= 0) || abs(cx - .5) > 1e-5 || abs(cy - .5) > 1e-5 ||
                (anisotropic && u32(b, start + 20) != 0L)) return null
            return Intrinsics(fx, fy, cx, cy)
        }

        private fun u16(b: ByteArray, at: Int): Int {
            require(at >= 0 && at.toLong() + 2 <= b.size) { "PHOTO_DECODE_FAILED" }
            return ((b[at].toInt() and 255) shl 8) or (b[at + 1].toInt() and 255)
        }
        private fun u32(b: ByteArray, at: Int): Long = (u16(b, at).toLong() shl 16) or u16(b, at + 2).toLong()
        private fun text(b: ByteArray, at: Int, n: Int): String {
            require(at >= 0 && at.toLong() + n <= b.size) { "PHOTO_DECODE_FAILED" }
            return String(b, at, n, Charsets.ISO_8859_1)
        }
        private fun id(b: ByteArray, at: Int, wide: Boolean): Int {
            val value = if (wide) u32(b, at) else u16(b, at).toLong()
            require(value in 1..Int.MAX_VALUE) { "PHOTO_DECODE_FAILED" }
            return value.toInt()
        }
        private fun boxes(b: ByteArray, start: Int, end: Int): List<Box> {
            val result = ArrayList<Box>(); var at = start
            require(start in 0..end && end <= b.size) { "PHOTO_DECODE_FAILED" }
            while (at < end) {
                require(end - at >= 8 && result.size < 65536) { "PHOTO_DECODE_FAILED" }
                var n = u32(b, at); var header = 8
                if (n == 1L) {
                    require(end - at >= 16 && u32(b, at + 8) == 0L) { "PHOTO_DECODE_FAILED" }
                    n = u32(b, at + 12); header = 16
                }
                if (n == 0L) n = (end - at).toLong()
                require(n >= header && n <= end.toLong() - at) { "PHOTO_DECODE_FAILED" }
                result.add(Box(at, at + header, at + n.toInt(), text(b, at + 4, 4)))
                at += n.toInt()
            }
            return result
        }
        private fun isHeif(b: ByteArray, body: Int, end: Int): Boolean {
            if (end - body < 8) return false
            if (text(b, body, 4) in brands) return true
            return (body + 8 until end step 4).any { it + 4 <= end && text(b, it, 4) in brands }
        }

        fun read(file: File): HeifPhotoInfo? = RandomAccessFile(file, "r").use { f ->
            var at = 0L; var heif = false; var meta: ByteArray? = null; var metaOffset = 0L; var count = 0
            while (at + 8 <= f.length()) {
                require(++count <= 4096) { "PHOTO_DECODE_FAILED" }
                f.seek(at); var n = f.readInt().toLong() and 0xffffffffL
                val type = ByteArray(4).also { f.readFully(it) }.toString(Charsets.ISO_8859_1)
                var header = 8
                if (n == 1L) { n = f.readLong(); header = 16 }
                if (n == 0L) n = f.length() - at
                if (n < header || n > f.length() - at) {
                    if (!heif && at == 0L) return@use null
                    error("PHOTO_DECODE_FAILED")
                }
                if (type == "ftyp") {
                    require(n <= 4096) { "PHOTO_DECODE_FAILED" }
                    val data = ByteArray((n - header).toInt()).also { f.readFully(it) }
                    heif = isHeif(data, 0, data.size)
                    if (!heif) return@use null
                } else if (type == "meta") {
                    require(meta == null && n <= MAX_META) { "PHOTO_DECODE_FAILED" }
                    metaOffset = at + header
                    meta = ByteArray((n - header).toInt()).also { f.readFully(it) }
                }
                at += n
            }
            if (!heif) null else parse(meta ?: error("PHOTO_DECODE_FAILED"), metaOffset)
        }

        /** A transfer prefix is useful as soon as its complete meta box arrives. */
        fun readPrefix(b: ByteArray): HeifPhotoInfo? {
            var at = 0; var heif = false
            while (at + 8 <= b.size) {
                val n = u32(b, at)
                if (n < 8 || n > b.size.toLong() - at) return null
                when (text(b, at + 4, 4)) {
                    "ftyp" -> { heif = isHeif(b, at + 8, at + n.toInt()); if (!heif) return null }
                    "meta" -> if (heif && n <= MAX_META) return parse(b.copyOfRange(at + 8, at + n.toInt()), (at + 8).toLong())
                }
                at += n.toInt()
            }
            return null
        }

        private fun parse(b: ByteArray, offset: Long): HeifPhotoInfo {
            require(b.size >= 4 && b[0].toInt() == 0) { "PHOTO_DECODE_FAILED" }
            val children = boxes(b, 4, b.size)
            val pitm = children.singleOrNull { it.type == "pitm" } ?: error("PHOTO_DECODE_FAILED")
            val version = b[pitm.body].toInt() and 255
            require(version in 0..1 && pitm.end - pitm.body >= if (version == 0) 6 else 8) { "PHOTO_DECODE_FAILED" }
            val primary = id(b, pitm.body + 4, version == 1)
            val types = HashMap<Int, String>(); val hidden = HashMap<Int, Long>()
            val iinf = children.singleOrNull { it.type == "iinf" } ?: error("PHOTO_DECODE_FAILED")
            require(iinf.end - iinf.body >= 6) { "PHOTO_DECODE_FAILED" }
            for (item in boxes(b, iinf.body + if (b[iinf.body].toInt() == 0) 6 else 8, iinf.end)) {
                if (item.type != "infe") continue
                require(item.end - item.body >= 12) { "PHOTO_DECODE_FAILED" }
                val v = b[item.body].toInt() and 255
                require(v == 2 || v == 3) { "PHOTO_DECODE_FAILED" }
                val itemId = id(b, item.body + 4, v == 3)
                require(!types.containsKey(itemId)) { "PHOTO_DECODE_FAILED" }
                types[itemId] = text(b, item.body + if (v == 3) 10 else 8, 4)
                hidden[itemId] = offset + item.body + 3
            }
            val groups = children.filter { it.type == "grpl" }.flatMap { boxes(b, it.body, it.end) }.filter { it.type == "ster" }
            require(groups.size <= 1) { "PHOTO_DECODE_FAILED" }
            var groupId: Int? = null
            val eyes = if (groups.isEmpty()) listOf(primary) else {
                val g = groups.single()
                require(g.end - g.body == 20 && b[g.body].toInt() == 0 && u32(b, g.body + 8) == 2L) { "PHOTO_DECODE_FAILED" }
                groupId = id(b, g.body + 4, true)
                listOf(id(b, g.body + 12, true), id(b, g.body + 16, true)).also {
                    require(it[0] != it[1]) { "PHOTO_DECODE_FAILED" }
                }
            }
            require(eyes.all { types[it] in imageTypes }) { "PHOTO_DECODE_FAILED" }
            val iprp = children.singleOrNull { it.type == "iprp" } ?: error("PHOTO_DECODE_FAILED")
            val propertyBoxes = boxes(b, iprp.body, iprp.end)
            val ipco = propertyBoxes.singleOrNull { it.type == "ipco" } ?: error("PHOTO_DECODE_FAILED")
            val properties = boxes(b, ipco.body, ipco.end).map { p ->
                when (p.type) {
                    "ispe" -> {
                        require(p.end - p.body == 12 && b[p.body].toInt() == 0) { "PHOTO_DECODE_FAILED" }
                        val w = u32(b, p.body + 4); val h = u32(b, p.body + 8)
                        require(w in 1..32768 && h in 1..32768) { "PHOTO_TOO_LARGE" }
                        Property(w.toInt(), h.toInt())
                    }
                    "irot" -> { require(p.end - p.body == 1); Property(rotate = (b[p.body].toInt() and 1) != 0) }
                    "cmin" -> Property(intrinsics = intrinsics(b, p.body, p.end), hasIntrinsics = true)
                    "clap" -> {
                        require(p.end - p.body == 32) { "PHOTO_DECODE_FAILED" }
                        fun dimension(at: Int): Int {
                            val denominator = u32(b, at + 4); require(denominator > 0) { "PHOTO_DECODE_FAILED" }
                            val value = (u32(b, at) + denominator / 2) / denominator
                            require(value in 1..32768) { "PHOTO_DECODE_FAILED" }
                            return value.toInt()
                        }
                        Property(crop = dimension(p.body) to dimension(p.body + 8),
                            centeredCrop = u32(b, p.body + 16) == 0L && u32(b, p.body + 20) > 0 &&
                                u32(b, p.body + 24) == 0L && u32(b, p.body + 28) > 0)
                    }
                    "uuid" -> {
                        val uuid = if (p.end - p.body >= 16) b.copyOfRange(p.body, p.body + 16).joinToString("") { "%02x".format(it.toInt() and 255) } else ""
                        if (uuid == disparityUuid) {
                            require(p.end - p.body == 20) { "PHOTO_DECODE_FAILED" }
                            val adjustment = u32(b, p.body + 16).toInt()
                            require(adjustment in -10000..10000) { "PHOTO_DECODE_FAILED" }
                            Property(disparity = adjustment / 10000.0)
                        } else if (uuid == intrinsicsUuid) Property(intrinsics = intrinsics(b, p.body + 16, p.end), hasIntrinsics = true)
                        else Property()
                    }
                    else -> Property()
                }
            }
            val associations = HashMap<Int, List<Int>>()
            for (ipma in propertyBoxes.filter { it.type == "ipma" }) {
                require(ipma.end - ipma.body >= 8) { "PHOTO_DECODE_FAILED" }
                val v = b[ipma.body].toInt() and 255; require(v in 0..1)
                val wide = (b[ipma.body + 3].toInt() and 1) != 0
                val entries = u32(b, ipma.body + 4); require(entries <= 65536)
                var at = ipma.body + 8
                repeat(entries.toInt()) {
                    require(at + (if (v == 0) 3 else 5) <= ipma.end) { "PHOTO_DECODE_FAILED" }
                    val item = id(b, at, v == 1); at += if (v == 0) 2 else 4
                    val n = b[at++].toInt() and 255
                    require(at + n * (if (wide) 2 else 1) <= ipma.end) { "PHOTO_DECODE_FAILED" }
                    val list = ArrayList<Int>()
                    repeat(n) {
                        val index = if (wide) u16(b, at) and 0x7fff else b[at].toInt() and 0x7f
                        at += if (wide) 2 else 1
                        require(index <= properties.size) { "PHOTO_DECODE_FAILED" }
                        if (index > 0) list.add(index - 1)
                    }
                    require(!associations.containsKey(item)) { "PHOTO_DECODE_FAILED" }
                    associations[item] = list
                }
                require(at == ipma.end) { "PHOTO_DECODE_FAILED" }
            }
            fun selected(item: Int) = associations[item].orEmpty().map { properties[it] }
            val sizes = eyes.map { eye ->
                val props = selected(eye); val size = props.singleOrNull { it.width > 0 } ?: error("PHOTO_DECODE_FAILED")
                val crop = props.mapNotNull { it.crop }.singleOrNull() ?: (size.width to size.height)
                require(crop.first <= size.width && crop.second <= size.height) { "PHOTO_DECODE_FAILED" }
                if (props.any { it.rotate }) crop.second to crop.first else crop
            }
            require(sizes.all { it == sizes.first() }) { "PHOTO_DECODE_FAILED" }
            val disparity = (groupId?.let { selected(it) }.orEmpty() + selected(eyes[0])).mapNotNull { it.disparity }.firstOrNull() ?: 0.0
            val groupProperties = groupId?.let { selected(it) }.orEmpty()
            fun fov(eye: Int): Double? {
                val props = selected(eye)
                val cameras = (props + groupProperties).filter { it.hasIntrinsics }
                if (cameras.any { it.intrinsics == null }) return null
                val camera = cameras.mapNotNull { it.intrinsics }.distinct().singleOrNull() ?: return null
                val size = props.single { it.width > 0 }
                if (props.any { !it.centeredCrop }) return null
                val crop = props.mapNotNull { it.crop }.singleOrNull() ?: (size.width to size.height)
                val rotated = props.any { it.rotate }
                val pixels = if (rotated) crop.second else crop.first
                val focal = if (rotated) camera.fy?.times(size.height) ?: (camera.fx * size.width) else camera.fx * size.width
                return Math.toDegrees(2 * atan(pixels / (2 * focal))).takeIf { it.isFinite() && it > 0 && it < 180 }
            }
            val fovs = if (eyes.size == 2) eyes.map { fov(it) } else emptyList()
            val horizontalFov = fovs.firstOrNull()?.takeIf { first -> fovs.all { it != null && abs(it - first) < .01 } }
            return HeifPhotoInfo(primary, offset + pitm.body + 4, if (version == 0) 2 else 4,
                eyes[0], eyes.getOrNull(1), sizes[0].first, sizes[0].second, hidden, disparity, horizontalFov)
        }
    }
}
