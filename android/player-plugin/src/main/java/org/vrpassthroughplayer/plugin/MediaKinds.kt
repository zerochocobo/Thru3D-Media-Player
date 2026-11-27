package org.vrpassthroughplayer.plugin

/** File type is independent from projection and stereo packing. */
internal object MediaKinds {
    val images = setOf("jpg", "jpeg", "png", "webp", "heic", "heif", "tif", "tiff", "hdr", "rgbe", "exr", "avif", "avifs", "apng", "gif", "dng", "cr2", "cr3", "nef", "nrw", "arw", "raf", "rw2", "orf", "pef", "srw")
    val audio = BackgroundAudioFiles.extensions
    val scenes = SceneFileImport.extensions
    fun audio(name: String) = name.substringBefore('?').substringBefore('#').substringAfterLast('.', "").lowercase() in audio
    fun image(name: String) = name.substringBefore('?').substringBefore('#').substringAfterLast('.', "").lowercase() in images
    fun pdf(name: String) = name.substringBefore('?').substringBefore('#').endsWith(".pdf", true)
    /** Reflowable books open in the reading mode, never in a media player. */
    fun book(name: String) = Books.named(name)
    fun scene(name: String) = name.substringBefore('?').substringBefore('#').substringAfterLast('.', "").lowercase() in scenes
    fun supported(name: String) = pdf(name) || book(name) || ArchiveKinds.named(name) || image(name) || audio(name) || scene(name) || DlnaClient.isVideoName(name) || StrmFile.named(name)
    fun kind(name: String) = if (pdf(name)) "pdf" else if (book(name)) "book" else if (ArchiveKinds.named(name)) "archive" else if (image(name)) "image" else if (audio(name)) "audio" else if (scene(name)) "scene" else "video"
    // Directory and search metadata contain literal filenames, including # and ?.
    // VIDEO_TS.IFO stands for its whole DVD folder; the other IFO/BUP files stay unlisted.
    fun listedFileName(name: String) = supportedFileName(name) || SidecarSubtitles.supportedFile(name)
    fun renameableFileName(name: String) = listedFileName(name) && !DvdFolderImage.index(name)
    fun fileNameKind(name: String) = name.substringAfterLast('.', "").lowercase().let { if (it == "pdf") "pdf" else if (it in Books.extensions) "book" else if (it in ArchiveKinds.extensions) "archive" else if (it in images) "image" else if (it in audio) "audio" else if (it in scenes) "scene" else if (SidecarSubtitles.supportedFile(name)) "subtitle" else "video" }
    fun supportedFileName(name: String) = name.substringAfterLast('.', "").lowercase().let { it == "pdf" || it in Books.extensions || it in ArchiveKinds.extensions || it in images || it in audio || it in scenes || it in DlnaClient.VIDEO_EXTENSIONS || it == "strm" } || DvdFolderImage.index(name)
}
