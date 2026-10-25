package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class PipClipTimelineTest {
    private fun recipe(id: Int = 0, x: Double = 0.0) = JSONObject().put("version",1).put("windows",JSONArray().put(JSONObject().apply {
        put("axes",JSONArray(listOf(50,0,0,0,50,0,0,0,50)))
        for(key in listOf("anchor","left","right")) put(key,JSONArray(listOf(x,0,2)))
        put("size",JSONArray(listOf(.48,.27)));put("feather",JSONArray(listOf(.025,.04)))
        put("crop",JSONArray(listOf(0,0,-1,1,0,0,0,1,0)));put("tangent",JSONArray(listOf(.3,.18)));put("source_eye",0)
        put("image",if(id==0)JSONObject() else JSONObject().put("id",id).put("orientation",1))
    }))
    @Test fun sourceTimeTracksMovesCloseAndOpeningMidClip() {
        val timeline=PipClipTimeline(100,{error("No images")},{})
        timeline.add(200,recipe(x=1.0));timeline.add(300,recipe(x=2.0));timeline.add(400,PipClipTimeline.empty())
        assertFalse(timeline.at(99).hasWindows());assertFalse(timeline.at(199).hasWindows())
        assertEquals(1f,timeline.at(299).packed()[9]);assertEquals(2f,timeline.at(300).packed()[9])
        assertFalse(timeline.at(400).hasWindows());assertTrue(timeline.composed);timeline.close()
    }
    @Test fun initialWindowsCoverKeyframePrerollAndPauseReplacesOnlySameSourceInstant() {
        val timeline=PipClipTimeline(100,{null},{})
        timeline.add(100,recipe(x=1.0));timeline.add(200,recipe(x=2.0));timeline.add(200,recipe(x=3.0))
        assertEquals(1f,timeline.at(0).packed()[9]);assertEquals(1f,timeline.at(199).packed()[9])
        assertEquals(3f,timeline.at(200).packed()[9]);timeline.close()
    }
    @Test fun pageTurnsAndRepeatedWindowsHoldOnlyOneLeasePerImageUntilSaveFinishes() {
        val retained=mutableListOf<Int>();val released=mutableListOf<Int>()
        val timeline=PipClipTimeline(0,{retained.add(it);File("preview-$it")},{released.add(it)})
        timeline.add(0,recipe(7));timeline.add(1,recipe(7,1.0));timeline.add(2,recipe(8));timeline.add(3,PipClipTimeline.empty())
        assertEquals(listOf(7,8),retained);assertTrue(released.isEmpty())
        assertEquals(7,timeline.at(1).previews()[0].first);assertEquals(8,timeline.at(2).previews()[0].first)
        timeline.close();timeline.close();assertEquals(listOf(7,8),released)
    }
    @Test fun rejectsBackwardClockAndMalformedRecipesWithoutReplacingAcceptedState() {
        val timeline=PipClipTimeline(100,{null},{})
        timeline.add(100,recipe())
        for (pair in listOf(99L to recipe(),101L to JSONObject(),102L to recipe(7))) {
            assertTrue(runCatching{timeline.add(pair.first,pair.second)}.isFailure)
            assertTrue(timeline.at(200).hasWindows())
        }
        timeline.close()
    }
    @Test fun previewBudgetStopsInsteadOfDroppingPagesAndReleasesAllLeases() {
        val released=mutableListOf<Int>();val timeline=PipClipTimeline(0,{File("preview-$it")},{released.add(it)})
        for(id in 1..128)timeline.add(id.toLong(),recipe(id))
        assertTrue(runCatching{timeline.add(129,recipe(129))}.isFailure)
        timeline.close();assertEquals((1..128).toList(),released)
    }
}
