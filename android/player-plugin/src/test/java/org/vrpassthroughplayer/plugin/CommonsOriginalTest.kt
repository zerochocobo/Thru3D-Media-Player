package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CommonsOriginalTest {
    @Test fun selectedFileIsResolvedFromDesktopMobileAndOverlayUrls() {
        for (page in listOf("https://commons.wikimedia.org/wiki/File:Sky_360.jpg?uselang=zh",
            "https://commons.m.wikimedia.org/wiki/Category:Panoramas#/media/File:Sky_360.jpg"))
            assertEquals("File:Sky_360.jpg",CommonsOriginal.title(page))
        assertEquals("File:'Imiloa.jpg",CommonsOriginal.title("https://commons.wikimedia.org/wiki/Category:Panoramas#/media/File:%27Imiloa.jpg"))
        assertNull(CommonsOriginal.title("https://example.org/wiki/File:Sky.jpg"))
        assertNull(CommonsOriginal.title("https://commons.wikimedia.org/wiki/Category:Panoramas"))
    }
    @Test fun imageinfoUsesOriginalUrlAndDimensionsInsteadOfTheThumbnail() {
        val root=JSONObject("""{"query":{"pages":{"1":{"imageinfo":[{"url":"https://upload.wikimedia.org/sky.jpg","thumburl":"https://thumb.wikimedia.org/320px-sky.jpg","width":12740,"height":6370,"size":18000000,"mime":"image/jpeg"}]}}}}""")
        val image=CommonsOriginal.parse(root)
        assertEquals("https://upload.wikimedia.org/sky.jpg",image.url)
        assertEquals(12740,image.width)
        root.getJSONObject("query").getJSONObject("pages").getJSONObject("1").getJSONArray("imageinfo").getJSONObject(0).put("width",320)
        assertTrue(runCatching { CommonsOriginal.parse(root) }.isFailure)
    }
}
