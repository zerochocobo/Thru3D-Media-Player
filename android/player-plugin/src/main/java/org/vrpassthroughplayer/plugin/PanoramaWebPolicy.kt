package org.vrpassthroughplayer.plugin

import java.net.URI

/** Only user navigations/downloads are candidates; page subresources must never open the player. */
internal object PanoramaWebPolicy {
    val imageTypes = setOf("image/jpeg", "image/png", "image/webp", "image/tiff", "image/vnd.radiance", "image/x-exr")
    fun allowed(url: String): Boolean = runCatching {
        val uri = URI(url)
        uri.scheme.equals("https", true) && !uri.host.isNullOrBlank() && uri.rawUserInfo == null &&
            url.length <= 8192 && url.none { it < ' ' }
    }.getOrDefault(false)
    fun imageNavigation(url: String, mainFrame: Boolean, method: String): Boolean =
        mainFrame && method == "GET" && allowed(url) && runCatching {
            val path = URI(url).path
            // MediaWiki's File:*.jpg is an HTML description/license page, not the image response.
            !path.startsWith("/wiki/") && path.substringAfterLast('.').lowercase() in setOf("jpg", "jpeg", "png", "webp", "tif", "tiff", "hdr", "rgbe", "exr")
        }.getOrDefault(false)
    fun mime(value: String): String = when(val type=value.substringBefore(';').trim().lowercase()) {
        "image/x-tiff", "application/tiff", "application/x-tiff" -> "image/tiff"
        "image/exr", "image/aces", "application/x-exr" -> "image/x-exr"
        "image/x-hdr", "image/hdr", "application/x-hdr", "image/x-rgbe" -> "image/vnd.radiance"
        else -> type
    }
    fun mediaOverlay(url: String): Boolean = allowed(url) && runCatching {
        val uri = URI(url)
        uri.host.lowercase() in setOf("commons.wikimedia.org","commons.m.wikimedia.org") && uri.fragment.orEmpty().startsWith("/media/File:")
    }.getOrDefault(false)
    fun imageHeader(bytes: ByteArray): Boolean {
        fun at(index: Int) = bytes[index].toInt() and 255
        if (bytes.size < 12) return false
        return PhotoBitmap.hdrHeader(bytes) || PhotoBitmap.tiffHeader(bytes) || (at(0) == 255 && at(1) == 216 && at(2) == 255) ||
            bytes.copyOfRange(0, 8).contentEquals(byteArrayOf(137.toByte(), 80, 78, 71, 13, 10, 26, 10)) ||
            (String(bytes, 0, 4, Charsets.ISO_8859_1) == "RIFF" && String(bytes, 8, 4, Charsets.ISO_8859_1) == "WEBP")
    }
    fun origin(url: String): String = if (allowed(url)) URI(url).let {
        "https://${it.host}${if (it.port > 0 && it.port != 443) ":${it.port}" else ""}/"
    } else ""
    fun highResolution(width: Int, height: Int): Boolean = width in 8192..65535 && height in 1..65535 &&
        width.toLong() * height <= 1_000_000_000L
}
