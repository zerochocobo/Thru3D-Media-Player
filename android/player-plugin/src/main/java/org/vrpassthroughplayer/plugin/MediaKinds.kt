package org.vrpassthroughplayer.plugin

/** File type is independent from projection and stereo packing. */
internal object MediaKinds {
    val images = setOf("jpg", "jpeg", "png", "webp", "heic", "heif")
    fun image(name: String) = name.substringBefore('?').substringBefore('#').substringAfterLast('.', "").lowercase() in images
    fun supported(name: String) = image(name) || DlnaClient.isVideoName(name)
    fun kind(name: String) = if (image(name)) "image" else "video"
    // Search metadata contains literal filenames, where # and ? are not URI delimiters.
    fun fileNameKind(name: String) = if (name.substringAfterLast('.', "").lowercase() in images) "image" else "video"
    fun supportedFileName(name: String) = name.substringAfterLast('.', "").lowercase().let { it in images || it in DlnaClient.VIDEO_EXTENSIONS }
}
