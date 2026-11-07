package org.vrpassthroughplayer.plugin

/** The page-keyboard path accepts committed text and existing navigation keys only.
 * It never creates an address editor or navigates to a string typed on the keyboard. */
internal object WebBrowserPageKeyboard {
    enum class Key { BACKSPACE, DELETE, ENTER, LEFT, RIGHT }
    sealed interface Input {
        data class Text(val value: String) : Input
        data class Press(val key: Key) : Input
    }
    fun input(command: String, value: String = ""): Input? = when (command) {
        "text" -> value.takeIf { it.isNotEmpty() && it.length <= 2048 && '\u0000' !in it }?.let { Input.Text(it) }
        "backspace" -> Input.Press(Key.BACKSPACE)
        "delete" -> Input.Press(Key.DELETE)
        "enter" -> Input.Press(Key.ENTER)
        "left" -> Input.Press(Key.LEFT)
        "right" -> Input.Press(Key.RIGHT)
        else -> null
    }
}
