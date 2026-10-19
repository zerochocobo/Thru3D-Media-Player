package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class VoiceCloneScanTest {
    private fun batch(start: Double,count: Int=1,eof: Boolean=false): JSONObject {
        val cues=JSONArray()
        repeat(count){index->cues.put(JSONObject().put("start",start+index*5).put("end",start+index*5+3).put("text","Sample $start $index"))}
        return JSONObject().put("cues",cues).put("eof",eof)
    }
    @Test fun doesNotStopAfterTheFirstNonemptyWindow() {
        var calls=0
        val result=VoiceCloneScan.read(0.0,0,read={start,_->calls++;batch(start,eof=calls==40)})
        assertEquals(32,calls);assertEquals(32,result.rows.length());assertFalse(result.eof)
    }
    @Test fun continuesPastLongGapsAndReportsTrueExhaustion() {
        var calls=0
        val result=VoiceCloneScan.read(0.0,0,read={start,_->calls++;batch(start,if(calls==12)2 else 0,calls==15)})
        assertEquals(15,calls);assertEquals(2,result.rows.length());assertTrue(result.eof)
    }
    @Test fun emptyVideoIsExhaustedRatherThanASuccessfulEmptyPage() {
        val result=VoiceCloneScan.read(0.0,0,read={_,_->batch(0.0,0,true)})
        assertEquals(0,result.rows.length());assertTrue(result.eof)
        assertTrue(VoiceClonePolicy.failureMessage("no_candidates").contains("3–10"))
    }
    @Test fun loadMoreAppendsAndDeduplicatesOverlappingCues() {
        val previous=VoiceClonePolicy.candidates(batch(0.0,3).getJSONArray("cues"),0)
        val result=VoiceCloneScan.read(0.0,0,previous,read={_,_->batch(0.0,5,true)})
        assertEquals(5,result.rows.length());assertTrue(result.eof)
        assertEquals(previous.getJSONObject(0).getString("key"),result.rows.getJSONObject(0).getString("key"))
    }
    @Test fun timeBudgetReturnsAnIncompletePageWithoutClaimingNoCandidates() {
        var clock=0L
        val result=VoiceCloneScan.read(0.0,0,now={clock},read={_,_->clock+=31_000_000_000L;batch(0.0,0)})
        assertFalse(result.eof);assertEquals(45.0,result.next,0.0)
    }
    @Test fun cancellationInterruptsScanningBeforeAnotherRead() {
        var calls=0
        assertThrows(IllegalStateException::class.java){
            VoiceCloneScan.read(0.0,0,active={check(calls<2)},read={start,_->calls++;batch(start,0)})
        }
        assertEquals(2,calls)
    }
}
