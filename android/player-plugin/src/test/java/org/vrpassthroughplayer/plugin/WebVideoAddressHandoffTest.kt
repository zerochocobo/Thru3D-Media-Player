package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WebVideoAddressHandoffTest {
    private val page = WebVideoPage.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    private fun media(identity: String) = JSONObject().put("capture_identity", identity).put("network_epoch", identity.substringAfterLast(':').toLong())

    @Test fun reloadedElementOfTheSameVideoIsNotAChange() {
        // An ad handing over to the video restarts the element: new id and epoch, same page.
        val before = media("3:7:1234:5:5"); val after = media("3:7:1234:9:9")
        assert(before.getString("capture_identity") != after.getString("capture_identity"))
        assertNull(WebVideoResolver.addressChange(page, 3, 3 to "https://www.youtube.com/watch?v=dQw4w9WgXcQ", after))
        // The element can also be missing for a moment, and the address may gain parameters.
        assertNull(WebVideoResolver.addressChange(page, 3, 3 to "https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=42s&pp=abc", null))
    }

    @Test fun anotherVideoTabOrPageIsAChange() {
        val same = media("3:7:1234:5:5")
        for (address in listOf("https://www.youtube.com/watch?v=aaaaaaaaaaa", "https://www.youtube.com/", "https://www.youtube.com/shorts/aaaaaaaaaaa",
            "https://vimeo.com/76979871", "about:blank"))
            assertEquals(address, "browser_page_changed", WebVideoResolver.addressChange(page, 3, 3 to address, same))
        assertEquals("browser_page_changed", WebVideoResolver.addressChange(page, 3, 4 to page.url, same))
        assertEquals("browser_page_changed", WebVideoResolver.addressChange(page, 3, null, null))
    }

    @Test fun protectedPlaybackOnTheSameVideoStillStopsTheHandoff() {
        assertEquals("protected_content", WebVideoResolver.addressChange(page, 3, 3 to page.url, media("3:7:1234:9:9").put("protected", true)))
    }
}
