package org.vrpassthroughplayer.plugin

/** Admission before MediaSources resolves an application-owned handle into a local playback lease. */
internal object MpvInputUri {
    private val schemes = setOf("content", "file", "usb", "smb", "cloud", "medialib", "dlna", "http", "https", "externalvideo", "airplayvideo")
    private val capture = Regex("webvideo://capture/[0-9a-f]{64}")

    fun accepts(uri: String): Boolean = when (uri.substringBefore(':', "")) {
        "webvideo" -> capture.matches(uri)
        else -> uri.substringBefore(':', "") in schemes
    }
}
