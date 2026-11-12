package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserDirectFileTest {
    private fun video(id: String) = JSONObject().put("direct_ready", true).put("selection", id)
    @Test fun currentPlayerWinsWithoutGuessingBySize() {
        val main = video("main").put("playing", true)
        val preload = video("preload").put("width", 8000)
        assertEquals("main", WebBrowserDirectFile.selection(listOf(main, preload)))
        preload.put("playing", true)
        assertEquals("", WebBrowserDirectFile.selection(listOf(main, preload)))
        main.put("fullscreen", true)
        assertEquals("main", WebBrowserDirectFile.selection(listOf(main, preload)))
        main.put("protected", true)
        assertEquals("", WebBrowserDirectFile.selection(listOf(main, preload)))
    }
    @Test fun pausedSingleFileStaysAvailableButASecondPausedVideoIsAmbiguous() {
        assertEquals("paused", WebBrowserDirectFile.selection(listOf(video("paused"))))
        assertEquals("", WebBrowserDirectFile.selection(listOf(video("paused"), video("other"))))
        assertEquals("", WebBrowserDirectFile.selection(emptyList()))
    }
}
