package org.vrpassthroughplayer.plugin

/** One attempt per actual fullscreen entry; returning to a failed entry must not retry. */
internal class WebBrowserFullscreen {
    var request = 0L; private set
    var active = false; private set
    var video = ""; private set
    fun update(fullscreen: Boolean, candidate: String) {
        if (!fullscreen || candidate.isEmpty()) { active = false; return }
        if (!active || video != candidate) { request++; video = candidate }
        active = true
    }
    fun matches(value: Long): Boolean = video.isNotEmpty() && request == value && value > 0
    fun reset() { active = false; video = ""; request++ }
}
