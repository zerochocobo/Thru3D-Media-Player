package org.vrpassthroughplayer.plugin

/** Keep UTF-8 filesystem names bounded and preserve the viewer's full-sphere naming convention. */
internal object PanoramaPictureName {
    fun extension(mime: String,title: String=""): String = when(mime) {
        "image/avif"->"avif";"image/gif"->"gif";"image/apng"->"apng";"image/heif"->"heif";"image/heic"->"heic"
        "image/png"->"png";"image/webp"->"webp";"image/tiff"->"tif";"image/vnd.radiance"->"hdr";"image/x-exr"->"exr"
        "image/x-camera-raw"->title.substringAfterLast('.').lowercase().takeIf {it in setOf("dng","cr2","cr3","nef","nrw","arw","raf","rw2","orf","pef","srw")} ?: error("Unsupported RAW original name")
        else->if(mime.startsWith("image/x-"))mime.substringAfterLast('-') else "jpg"
    }
    fun make(title: String, mime: String, spherical: Boolean): String {
        val extension = extension(mime,title)
        var base = title.substringAfterLast('/').substringAfterLast('\\').substringBeforeLast('.')
            .replace(Regex("[^\\p{L}\\p{N}._ -]"), "_").trim(' ', '.')
        if (base.isBlank()) base = "panorama"
        while (base.toByteArray(Charsets.UTF_8).size > 160) base = base.dropLast(1)
        if (spherical && !base.endsWith("_360_2D", true)) base += "_360_2D"
        return "$base.$extension"
    }
}
