package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONArray

class NarrationTimelineTest {
    @Test fun sharedQueueRejectsOldSeeksTracksAndCommands() {
        val snapshot=org.json.JSONObject().put("supported",true).put("track_id","3").put("source_epoch",7)
            .put("command_id",9).put("observed_monotonic_ns",1_000_000_000L).put("cues",batch(12.0).cues)
        assertEquals(1,NarrationTimeline.shared(snapshot,3,7,9,1_500_000_000L)!!.length())
        assertNull(NarrationTimeline.shared(snapshot,4,7,9,1_500_000_000L))
        assertNull(NarrationTimeline.shared(snapshot,3,8,9,1_500_000_000L))
        assertNull(NarrationTimeline.shared(snapshot,3,7,10,1_500_000_000L))
        assertNull(NarrationTimeline.shared(snapshot,3,7,9,2_500_000_000L))
        val text=NarrationTimeline();text.remember(snapshot.getJSONArray("cues"))
        assertFalse(text.covers(12.0,15.0)) // A partial queue cannot claim full extraction.
    }
    private fun batch(start: Double, eof: Boolean=false, duration: Double=180.0)=NarrationTimeline.Batch(
        JSONArray().put(org.json.JSONObject().put("start",start).put("end",start+3).put("text","English\n中文")),eof,duration)
    @Test fun seekKeepsRawTextAndGapsAreNotMistakenForComplete() {
        val text=NarrationTimeline()
        text.accept(0.0,45.0,batch(1.0));text.accept(90.0,135.0,batch(91.0))
        assertTrue(text.covers(0.0,45.0));assertTrue(text.covers(90.0,130.0));assertFalse(text.covers(30.0,100.0))
        assertEquals(45.0 to 90.0,text.nextWindow());assertEquals(2,text.size);assertFalse(text.complete)
        // The same stored cue can be reselected after a seek, locale or line change.
        assertEquals("中文",NarrationPolicy.cues(text.window(0.0,45.0),"zh",2).single().text)
        assertEquals("English",NarrationPolicy.cues(text.window(0.0,45.0),"en",1).single().text)
    }
    @Test fun wholeTrackCompletesWithOverlapsAndDeduplicatesEvents() {
        val text=NarrationTimeline()
        for(start in listOf(90.0,0.0,45.0,135.0))text.accept(start,start+45,batch(start+1))
        text.accept(0.0,45.0,batch(1.0))
        assertTrue(text.complete);assertEquals(4,text.size);assertEquals(1.0,text.fraction,0.0)
        assertNull(text.nextWindow());assertTrue(text.covers(170.0,215.0))
    }
    @Test fun emptySubtitleWindowsAreStillCached() {
        val text=NarrationTimeline();text.accept(0.0,45.0,NarrationTimeline.Batch(JSONArray(),false,90.0))
        assertTrue(text.covers(1.0,44.0));assertEquals(0,text.size);assertFalse(text.complete)
        assertEquals(45.0 to 90.0,text.nextWindow())
    }
    @Test fun eofDoesNotClaimAnUnvisitedBeginningIsCached() {
        val text=NarrationTimeline();text.accept(135.0,180.0,batch(136.0,true))
        assertFalse(text.complete);assertEquals(0.0 to 45.0,text.nextWindow())
        val unknown=NarrationTimeline();unknown.accept(0.0,45.0,NarrationTimeline.Batch(JSONArray(),true,0.0))
        assertTrue(unknown.complete)
    }
    @Test fun limitsPreserveExistingTextAndDisableBackgroundGrowth() {
        val text=NarrationTimeline(120)
        assertTrue(text.accept(0.0,45.0,batch(1.0)))
        assertFalse(text.accept(45.0,90.0,batch(46.0)))
        assertTrue(text.limited);assertEquals(1,text.size);assertTrue(text.covers(0.0,45.0))
        assertFalse(text.covers(45.0,90.0));assertNull(text.nextWindow())
    }
    @Test fun errorDiagnosticsContainOnlyKnownStagesAndNumericCodes() {
        for(code in listOf("subtitle_seek_timeout:-1","subtitle_open:-5","subtitle_read_timeout:0")) {
            assertEquals(code,NarrationTimeline.errorCode(IllegalStateException(code)));assertTrue(NarrationTimeline.retryable(code))
        }
        assertEquals("subtitle_internal:0",NarrationTimeline.errorCode(IllegalStateException("http://secret/film?token=private")))
        assertFalse(NarrationTimeline.retryable("subtitle_text_required:0"))
    }
    @Test fun displayedCueUsesSharedTimingAndDoesNotInventCoverage() {
        val snapshot=org.json.JSONObject().put("timeline_valid",true).put("track_id","2")
            .put("start_seconds","10.0").put("end_seconds","14.0").put("text","English\n中文")
        val raw=NarrationTimeline.visible(snapshot,12.0,1.0,2)
        val text=NarrationTimeline();assertTrue(text.remember(raw));assertEquals(1,text.size)
        assertFalse(text.covers(10.0,14.0));assertEquals("中文",NarrationPolicy.cues(raw,"zh",2).single().text)
        assertEquals(0,NarrationTimeline.visible(snapshot,9.0,1.0,2).length())
        assertEquals(0,NarrationTimeline.visible(snapshot,12.0,1.0,3).length())
        snapshot.put("timeline_valid",false);assertEquals(0,NarrationTimeline.visible(snapshot,12.0,1.0,2).length())
    }
    @Test fun latePrefetchCannotRepeatAPlaybackCueWithDifferentTiming() {
        val live=NarrationPolicy.Cue(10.0,14.0,"中文")
        val rounded=NarrationPolicy.Cue(10.00001,14.00001,"中文")
        val future=NarrationPolicy.Cue(16.0,20.0,"Next")
        val merged=NarrationPolicy.mergeDisplayed(listOf(rounded,future),listOf(live))
        assertEquals(listOf(live,future),merged.first);assertEquals(listOf(rounded.key),merged.second)
        assertEquals(listOf(live),NarrationPolicy.mergeDisplayed(listOf(live),listOf(live)).first)
        val parts=listOf(live.copy(end=12.0),live.copy(start=12.0))
        assertEquals(parts,NarrationPolicy.mergeDisplayed(parts,parts).first)
        assertTrue(NarrationPolicy.mergeDisplayed(parts,parts).second.isEmpty())
    }
}
