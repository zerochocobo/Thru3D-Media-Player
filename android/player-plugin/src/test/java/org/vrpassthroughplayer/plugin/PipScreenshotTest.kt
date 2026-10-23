package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class PipScreenshotTest {
    private fun window(image: Int = 0): JSONObject = JSONObject().apply {
        put("axes", JSONArray(listOf(50,0,0,0,50,0,0,0,50)))
        for (key in listOf("anchor","left","right")) put(key,JSONArray(listOf(0,0,2)))
        put("size",JSONArray(listOf(.48,.27))); put("feather",JSONArray(listOf(.025,.04)))
        put("crop",JSONArray(listOf(0,0,-1,1,0,0,0,1,0))); put("tangent",JSONArray(listOf(.3,.18)))
        put("source_eye",0)
        put("image",if(image==0)JSONObject() else JSONObject().put("id",image).put("orientation",6))
    }
    private fun recipe(vararg windows: JSONObject) = JSONObject().put("version",1).put("windows",JSONArray(windows.toList()))

    @Test fun pinBeforeWorkerAndReleaseEachLeaseExactlyOnce() {
        val retained=mutableListOf<Int>();val released=mutableListOf<Int>()
        val job=PipScreenshot(recipe(window(7),window(),window(7)),{id->retained.add(id);File("preview-$id.png")},{released.add(it)})
        assertTrue(job.hasWindows());assertEquals(listOf(7,7),retained);assertTrue(released.isEmpty())
        job.close();job.close();assertEquals(listOf(7,7),released)
    }
    @Test fun incompleteImageFailsAndReleasesAlreadyPinnedImages() {
        val released=mutableListOf<Int>()
        try {
            PipScreenshot(recipe(window(7),window(8)),{id->if(id==7)File("preview.png") else null},{released.add(it)})
            fail("Missing image silently accepted")
        } catch (_: IllegalStateException) { }
        assertEquals(listOf(7),released)
    }
    @Test fun invalidRecipesCannotRequestSourceReadsOrUnlimitedImages() {
        val invalid=listOf(recipe(window(),window(),window(),window()),recipe(window().put("axes",JSONArray(listOf(1)))),
            recipe(window().put("source_eye",3)),recipe(window(1).apply { getJSONObject("image").put("orientation",9) }))
        for (value in invalid) {
            var reads=0
            try { PipScreenshot(value,{reads++;File("never")},{ });fail("Invalid recipe accepted") }
            catch (_: IllegalArgumentException) { }
            assertEquals(0,reads)
        }
    }
    @Test fun emptyLayoutNeedsNoImageOrCompositorWork() {
        val job=PipScreenshot(recipe(),{error("Unexpected preview read")},{error("Unexpected release")})
        assertFalse(job.hasWindows());job.close()
    }
    @Test fun aCleanupFailureCannotLeakTheOtherImageLeases() {
        val released=mutableListOf<Int>()
        val job=PipScreenshot(recipe(window(1),window(2)),{File("preview-$it")},{released.add(it);if(it==1)error("Cleanup failed")})
        job.close();job.close();assertEquals(listOf(1,2),released)
    }
}
