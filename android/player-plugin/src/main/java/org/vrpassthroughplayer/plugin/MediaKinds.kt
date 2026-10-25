package org.vrpassthroughplayer.plugin

/** File type is independent from projection and stereo packing. */
internal object MediaKinds {
    val images = setOf("jpg", "jpeg", "png", "webp", "heic", "heif", "tif", "tiff", "hdr", "rgbe", "exr")
    val audio = BackgroundAudioFiles.extensions
    fun audio(name: String) = name.substringBefore('?').substringBefore('#').substringAfterLast('.', "").lowercase() in audio
    fun image(name: String) = name.substringBefore('?').substringBefore('#').substringAfterLast('.', "").lowercase() in images
    fun pdf(name: String) = name.substringBefore('?').substringBefore('#').endsWith(".pdf", true)
    fun supported(name: String) = pdf(name) || ArchiveKinds.named(name) || image(name) || audio(name) || DlnaClient.isVideoName(name) || StrmFile.named(name)
    fun kind(name: String) = if (pdf(name)) "pdf" else if (ArchiveKinds.named(name)) "archive" else if (image(name)) "image" else if (audio(name)) "audio" else "video"
    // Search metadata contains literal filenames, where # and ? are not URI delimiters.
    fun fileNameKind(name: String) = name.substringAfterLast('.', "").lowercase().let { if (it == "pdf") "pdf" else if (it in ArchiveKinds.extensions) "archive" else if (it in images) "image" else if (it in audio) "audio" else "video" }
    fun supportedFileName(name: String) = name.substringAfterLast('.', "").lowercase().let { it == "pdf" || it in ArchiveKinds.extensions || it in images || it in audio || it in DlnaClient.VIDEO_EXTENSIONS || it == "strm" }
}
