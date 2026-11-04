package org.vrpassthroughplayer.plugin

/** No field contents: a lease identifies one editor, including focus changes within a page. */
internal class WebBrowserKeyboardSession {
    data class Target(val window: Int, val tab: Int, val navigation: Long, val epoch: Long)
    private var sequence = 0L
    @Volatile var target: Target? = null
        private set
    fun open(window: Int, tab: Int, navigation: Long): Target =
        Target(window, tab, navigation, ++sequence).also { target = it }
    fun close() { target = null }
    fun accepts(candidate: Target): Boolean = target == candidate
}
