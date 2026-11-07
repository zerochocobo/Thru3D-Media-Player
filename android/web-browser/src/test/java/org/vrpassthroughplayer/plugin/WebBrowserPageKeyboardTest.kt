package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class WebBrowserPageKeyboardTest {
    @Test fun numbersAndLettersRemainPageKeysWithoutAnEditor() {
        for (value in listOf("0", "5", "9", "j", "k", "m", " ", "https://example.test/", "中文🙂")) {
            assertEquals(WebBrowserPageKeyboard.Input.Text(value), WebBrowserPageKeyboard.input("text", value))
        }
    }
    @Test fun navigationKeysAreNotAddressSubmission() {
        for ((command, key) in listOf("backspace" to WebBrowserPageKeyboard.Key.BACKSPACE,
            "delete" to WebBrowserPageKeyboard.Key.DELETE, "enter" to WebBrowserPageKeyboard.Key.ENTER,
            "left" to WebBrowserPageKeyboard.Key.LEFT, "right" to WebBrowserPageKeyboard.Key.RIGHT)) {
            assertEquals(WebBrowserPageKeyboard.Input.Press(key), WebBrowserPageKeyboard.input(command))
        }
        assertNull(WebBrowserPageKeyboard.input("navigate", "https://example.test/"))
        assertNull(WebBrowserPageKeyboard.input("paste", "https://example.test/"))
    }
    @Test fun invalidAndUnboundedTextCannotBecomeKeys() {
        for (text in listOf("", "a\u0000b", "x".repeat(2049))) assertNull(WebBrowserPageKeyboard.input("text", text))
        assertNotNull(WebBrowserPageKeyboard.input("text", "x".repeat(2048)))
    }
    @Test fun pendingPageKeystrokesCannotCrossAFieldOrTabChange() {
        val session = WebBrowserKeyboardSession()
        val page = session.open(1, 4, 8)
        assertTrue(session.accepts(page))
        val field = session.open(1, 4, 8)
        assertFalse(session.accepts(page)); assertTrue(session.accepts(field))
        val navigated = session.open(1, 4, 9)
        assertFalse(session.accepts(field)); assertTrue(session.accepts(navigated))
        session.close()
        assertFalse(session.accepts(navigated))
    }
}
