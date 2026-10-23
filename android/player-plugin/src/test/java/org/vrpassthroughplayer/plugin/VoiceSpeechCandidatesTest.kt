package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONArray

class VoiceSpeechCandidatesTest {
    private fun run(seconds: Double,offset: Double=0.0,signal: (Double)->Triple<Float,Float,Float>): JSONArray {
        val scan=VoiceSpeechCandidates(offset,offset+seconds,2)
        var frame=0;var rows=JSONArray()
        val count=(seconds/VoiceSpeechCandidates.STEP).toInt()
        while(frame<count){val n=minOf(32,count-frame);val values=(0 until n).map {signal((frame+it)*VoiceSpeechCandidates.STEP)}
            rows=scan.accept(offset+frame*VoiceSpeechCandidates.STEP,values.map {it.first}.toFloatArray(),values.map {it.second}.toFloatArray(),values.map {it.third}.toFloatArray(),frame+n==count)
            frame+=n
        }
        return rows
    }
    private fun speech(on: Boolean)=if(on)Triple(.95f,.06f,.35f) else Triple(.01f,.0001f,.001f)
    @Test fun crossesCallbackBoundariesAndKeepsSourceTimes() {
        val rows=run(12.0,600.0){speech(it in 1.0..7.0)}
        assertEquals(1,rows.length());val row=rows.getJSONObject(0)
        assertEquals(600.9,row.getDouble("start"),.05);assertEquals(607.08,row.getDouble("end"),.06)
        assertEquals("audio",row.getString("timing"));assertEquals(32,row.getJSONArray("waveform").length())
    }
    @Test fun doesNotJoinShortUtterancesAcrossSilence() {
        assertEquals(0,run(12.0){speech(it in 0.5..2.5||it in 3.0..5.0||it in 6.0..8.0)}.length())
    }
    @Test fun refusesLongContinuousSpeechInsteadOfCuttingWords() {
        val rows=run(30.0){speech(it in 0.0..15.0||it in 17.0..23.0)}
        assertEquals(1,rows.length());assertTrue(rows.getJSONObject(0).getDouble("start")>16)
    }
    @Test fun rejectsSilenceMusicWithoutVadAndLowLevelOrClippedAudio() {
        assertEquals(0,run(10.0){Triple(.01f,.2f,.8f)}.length())
        assertEquals(0,run(10.0){if(it<6)speech(true).copy(second=.0001f) else speech(false)}.length())
        assertEquals(0,run(10.0){if(it<6)speech(true).copy(third=1f) else speech(false)}.length())
    }
    @Test fun finalCandidateStaysWithinAudioAtEof() {
        val row=run(6.4,12.0){speech(true)}.getJSONObject(0)
        assertEquals(12.0,row.getDouble("start"),0.001);assertTrue(row.getDouble("end")<=18.4)
    }
    @Test fun identityIncludesTrackAndTimeButNotSubtitleText() {
        val a=VoiceSpeechCandidates.candidate(1.0,7.0,2)
        assertEquals(a.getString("key"),VoiceSpeechCandidates.candidate(1.0,7.0,2,true).getString("key"))
        assertNotEquals(a.getString("key"),VoiceSpeechCandidates.candidate(1.0,7.0,3).getString("key"))
        assertNotEquals(a.getString("key"),VoiceSpeechCandidates.candidate(1.1,7.0,2).getString("key"))
    }
    @Test fun invalidAndOutOfSourceRangesAreRejected() {
        for(range in listOf(-1.0 to 5.0,1.0 to Double.NaN,1.0 to 1.0,0.0 to 601.0,5.0 to 12.0)){
            assertThrows(IllegalArgumentException::class.java){VoiceSpeechCandidates.range(range.first,range.second,600.0,10.0)}
        }
        assertThrows(IllegalArgumentException::class.java){VoiceSpeechCandidates.candidate(0.0,2.9,1)}
        VoiceSpeechCandidates.candidate(0.0,3.0,1);VoiceSpeechCandidates.candidate(0.0,10.0,1)
    }
    @Test fun cropKeepsOtherCandidatesAndCanResetAfterRepeatedChanges() {
        val first=VoiceSpeechCandidates.candidate(600.0,608.0,1).put("waveform",JSONArray(listOf(.1,.2)))
        val second=VoiceSpeechCandidates.candidate(620.0,630.0,1)
        val source=JSONArray(listOf(first,second));val key=first.getString("key")
        val crop=VoiceSpeechCandidates.trim(source,key,601.0,606.0)
        assertEquals(2,crop.length());assertEquals(second.toString(),crop.getJSONObject(1).toString())
        assertEquals(600.0,first.getDouble("start"),0.0) // Original snapshot is immutable.
        assertEquals(key,crop.getJSONObject(0).getString("key"))
        assertFalse(crop.getJSONObject(0).has("waveform"))
        val shorter=VoiceSpeechCandidates.trim(crop,key,602.0,605.0)
        val reset=VoiceSpeechCandidates.trim(shorter,key,600.0,608.0).getJSONObject(0)
        assertEquals(600.0,reset.getDouble("start"),0.0);assertEquals(608.0,reset.getDouble("end"),0.0)
        assertEquals(first.getJSONArray("waveform").toString(),reset.getJSONArray("original_waveform").toString())
    }
    @Test fun cropRejectsExpansionAndLessThanThreeSeconds() {
        val row=VoiceSpeechCandidates.candidate(100.0,108.0,1);val key=row.getString("key");val rows=JSONArray(listOf(row))
        for(pair in listOf(99.0 to 105.0,104.0 to 109.0,101.0 to 103.9,Double.NaN to 108.0))
            assertThrows(IllegalArgumentException::class.java){VoiceSpeechCandidates.trim(rows,key,pair.first,pair.second)}
        assertThrows(IllegalStateException::class.java){VoiceSpeechCandidates.trim(rows,"missing",100.0,103.0)}
        assertThrows(IllegalArgumentException::class.java){VoiceSpeechCandidates.trim(JSONArray(listOf(row.put("timing","subtitle"))),key,100.0,103.0)}
    }
    @Test fun cropNormalizesFloatUiRoundoffToAnExactThreeSecondMinimum() {
        val row=VoiceSpeechCandidates.candidate(600.032,608.032,1)
        val cropped=VoiceSpeechCandidates.trim(JSONArray(listOf(row)),row.getString("key"),600.03198,603.03197).getJSONObject(0)
        assertTrue(cropped.getDouble("start")>=600.032)
        assertTrue(cropped.getDouble("end")-cropped.getDouble("start")>=3.0)
    }
}
