package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ComicSpeechRoutingTest {
    @Test fun everyNarrationLanguageCanRouteTranslatedComicText(){
        assertEquals(19,NarrationPolicy.languages.size)
        val r=ComicSpeechRouting();r.page(1)
        for(language in NarrationPolicy.languages){
            r.mode(language,language)
            val text=NarrationPolicy.previewText(language)
            assertTrue(r.update(1,language,JSONArray().put(row(text=text))))
            assertEquals(language,r.resolve(0,3,"Original","en")!!.language)
            assertEquals(text,r.resolve(0,3,"Original","en")!!.text)
        }
        assertThrows(IllegalArgumentException::class.java){r.mode("unsupported","xx")}
    }
    private fun row(page: Int=0,id: Int=3,text: String="Wait!")=JSONObject().put("page",page).put("id",id).put("text",text)
    @Test fun translatedModeWaitsAndRejectsOldPageAndLanguageResponses(){
        val r=ComicSpeechRouting();r.page(1)
        assertEquals("待って！",r.resolve(0,3,"待って！","ja")!!.text)
        assertTrue(r.mode("english-1","en"))
        assertNull(r.resolve(0,3,"待って！","ja"))
        assertFalse(r.update(0,"english-1",JSONArray().put(row())))
        assertFalse(r.update(1,"old",JSONArray().put(row())))
        assertTrue(r.update(1,"english-1",JSONArray().put(row())))
        val translated=r.resolve(0,3,"待って！","ja")!!
        assertEquals("Wait!",translated.text);assertEquals("en",translated.language)
        assertTrue(translated.suffix.startsWith(":translated:en:"))
        assertNull(r.resolve(1,3,"別ページ","ja"))
        r.mode("chinese-2","zh");assertNull(r.resolve(0,3,"待って！","ja"))
        assertFalse(r.update(1,"english-1",JSONArray().put(row())))
        r.page(2);assertFalse(r.update(1,"chinese-2",JSONArray().put(row())))
        r.mode("original","");assertEquals("ja",r.resolve(0,3,"待って！","ja")!!.language)
        assertEquals("",r.resolve(0,3,"待って！","ja")!!.suffix)
        assertFalse(r.update(2,"original",JSONArray().put(row())))
    }
    @Test fun cacheIdentityTracksTextAndTargetAndInvalidBatchIsAtomic(){
        val r=ComicSpeechRouting();r.page(4);r.mode("a","en")
        r.update(4,"a",JSONArray().put(row()));val first=r.resolve(0,3,"","ja")!!
        r.update(4,"a",JSONArray().put(row(text="Stop!")))
        assertNotEquals(first.suffix,r.resolve(0,3,"","ja")!!.suffix)
        assertThrows(IllegalArgumentException::class.java){r.update(4,"a",JSONArray().put(row()).put(row()))}
        assertEquals("Stop!",r.resolve(0,3,"","ja")!!.text)
        r.update(4,"a",JSONArray().put(row()).put(row(page=1,text="Go!")))
        assertEquals("Go!",r.resolve(1,3,"","ja")!!.text)
        assertFalse(r.mode("a","en"));assertNotNull(r.resolve(1,3,"","ja"))
    }
}
