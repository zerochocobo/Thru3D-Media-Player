package org.vrpassthroughplayer.plugin

/** Keep UTF-8 filesystem names bounded and preserve the viewer's full-sphere naming convention. */
internal object PanoramaPictureName {
    fun make(title: String, mime: String, spherical: Boolean): String {
        val extension = when (mime) { "image/png" -> "png"; "image/webp" -> "webp"; "image/tiff" -> "tif"; "image/vnd.radiance" -> "hdr"; "image/x-exr" -> "exr"; else -> "jpg" }
        var base = title.substringAfterLast('/').substringAfterLast('\\').substringBeforeLast('.')
            .replace(Regex("[^\\p{L}\\p{N}._ -]"), "_").trim(' ', '.')
        if (base.isBlank()) base = "panorama"
        while (base.toByteArray(Charsets.UTF_8).size > 160) base = base.dropLast(1)
        if (spherical && !base.endsWith("_360_2D", true)) base += "_360_2D"
        return "$base.$extension"
    }
}
