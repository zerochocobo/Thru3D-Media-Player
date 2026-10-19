package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class VoiceClonePolicyTest {
    @Test fun independentReferenceLeaseReleasesExactlyOnceOnSuccessFailureAndCancellation() {
        for(fail in listOf(false,true)) {
            var releases=0
            val reference=VoiceClonePolicy.Reference("independent") {releases++}
            runCatching {reference.use {assertEquals("independent",it.path);if(fail)error("cancelled")}}
            reference.close()
            assertEquals(1,releases)
        }
    }
    @Test fun sourceReferenceHealthContainsNoSubtitleNamesOrSourceAddresses() {
        val state=JSONObject().put("state","ready").put("played_frames",144000).put("voices",JSONArray().put("private-name"))
            .put("candidates",JSONArray().put(JSONObject().put("key","sample-hash").put("text","private-subtitle")))
            .put("path","http://private/source").put("preview_id","private-voice")
        val health=VoiceClonePolicy.referenceHealth(state)
        assertEquals(1,health.getInt("candidate_count"));assertEquals("sample-hash",health.getString("probe_candidate_key"))
        assertFalse(health.toString().contains("private"));assertEquals(144000,health.getInt("played_frames"))
    }
    @Test fun independentDlnaCaptionWithMissingIndexUsesItsOwnStreamAndLease() {
        val movie="http://127.0.0.1:32100/movie.mp4"
        val subtitle="http://127.0.0.1:32101/caption/subtitle.srt"
        val track=JSONObject().put("external",true).put("filename",subtitle).put("stream_index",-1)
        assertEquals(VoiceClonePolicy.Input(subtitle,0,false),VoiceClonePolicy.input(movie,track,true))
        track.remove("stream_index")
        assertEquals(0,VoiceClonePolicy.input(movie,track).stream)
        track.put("stream_index",2)
        assertEquals(2,VoiceClonePolicy.input(movie,track).stream)
    }
    @Test fun internalIndexesAndDiscModeStayBoundToTheirOriginalSource() {
        assertEquals(VoiceClonePolicy.Input("disc",4,true),VoiceClonePolicy.input("disc",JSONObject().put("stream_index",4),true))
        assertThrows(IllegalStateException::class.java){VoiceClonePolicy.input("movie",JSONObject().put("stream_index",-1))}
        assertThrows(IllegalStateException::class.java){VoiceClonePolicy.input("movie",JSONObject().put("external",true).put("filename",""))}
    }
    @Test fun diagnosticRetainsNativeStagesAndCodesWithoutPathsOrCredentials() {
        for(detail in listOf("subtitle_open:-5","subtitle_seek_timeout:-110","voice_extract:Audio source unavailable:-5"))
            assertEquals(detail,VoiceClonePolicy.diagnostic(IllegalStateException(detail)))
        for(detail in listOf("http://private/video?token=secret","voice_extract:Audio read failed /private/path","subtitle_open:-5 token=secret"))
            assertEquals("internal",VoiceClonePolicy.diagnostic(IllegalStateException(detail)))
    }
    @Test fun previewsUseTheSameVolumeAsNarrationButOriginalRetainsVideoLevel() {
        assertEquals(.3f,VoiceClonePolicy.playbackGain(60.0,.5,false),.000001f)
        assertEquals(.6f,VoiceClonePolicy.playbackGain(60.0,.5,true),.000001f)
        assertEquals(0f,VoiceClonePolicy.playbackGain(80.0,0.0,false),0f)
        assertEquals(1f,VoiceClonePolicy.playbackGain(100.0,1.0,false),0f)
        assertThrows(IllegalArgumentException::class.java){VoiceClonePolicy.playbackGain(Double.NaN,1.0,false)}
    }
    @Test fun automaticAudioSelectionUsesTheObservedTrackOrAUsableFallback() {
        val details=JSONObject().put("audio_track_id","auto").put("audio_tracks",JSONArray()
            .put(JSONObject().put("id",1).put("stream_index",2)).put(JSONObject().put("id",4).put("stream_index",5)))
        assertEquals(1,VoiceClonePolicy.audioTrack(-1,details).getInt("id"))
        details.put("audio_track_id","4")
        assertEquals(4,VoiceClonePolicy.audioTrack(0,details).getInt("id"))
        assertEquals(1,VoiceClonePolicy.audioTrack(1,details).getInt("id"))
        assertThrows(IllegalStateException::class.java){VoiceClonePolicy.audioTrack(99,details)}
        assertThrows(IllegalStateException::class.java){VoiceClonePolicy.audioTrack(-1,JSONObject())}
    }
    @Test fun extractionAndPlaybackErrorsRemainDistinctFromEncoding() {
        assertEquals("extract_failed",VoiceClonePolicy.failureCode("original","extracting",IllegalStateException("voice_extract:Audio seek failed")))
        assertEquals("encode_failed",VoiceClonePolicy.failureCode("clone","encoding",IllegalStateException()))
        assertEquals("preview_muted",VoiceClonePolicy.failureCode("original","playing_original",IllegalStateException("voice_preview_muted")))
        assertNotEquals(VoiceClonePolicy.failureMessage("extract_failed"),VoiceClonePolicy.failureMessage("encode_failed"))
    }
    @Test fun secondPressStopsTheSameAuditionBeforeUiStatusCatchesUp() {
        for(op in listOf("original","clone","preview")){
            val command=JSONObject().put("operation",op).put("key","caption-a").put("id","voice-a")
            val state=JSONObject().put("operation",op).put("active_key","caption-a").put("preview_id","voice-a")
            for(phase in listOf("preparing","model_verifying","model_loading",if(op=="original")"playing_original" else "playing_clone")){
                state.put("state",phase);assertEquals("stop",VoiceClonePolicy.operation(command,state))
            }
            state.put("state","ready");assertEquals(op,VoiceClonePolicy.operation(command,state))
        }
    }
    @Test fun anotherCandidateOrVoiceStartsANewAudition() {
        val active=JSONObject().put("operation","clone").put("active_key","old").put("state","encoding")
        assertEquals("clone",VoiceClonePolicy.operation(JSONObject().put("operation","clone").put("key","new"),active))
        assertEquals("original",VoiceClonePolicy.operation(JSONObject().put("operation","original").put("key","old"),active))
        active.put("operation","preview").put("preview_id","old").put("state","generating")
        assertEquals("preview",VoiceClonePolicy.operation(JSONObject().put("operation","preview").put("id","new"),active))
    }
    private fun cue(start: Double,end: Double,text: String)=JSONObject().put("start",start).put("end",end).put("text",text)
    @Test fun durationBoundsAndAuthoredLinesAreUsedBeforeSpeechChunking() {
        val input=JSONArray().put(cue(0.0,3.0,"中文\n日本語")).put(cue(5.0,15.0,"很长的句子。".repeat(20)))
            .put(cue(20.0,22.999,"short")).put(cue(30.0,40.001,"long")).put(cue(50.0,55.0,""))
        val result=VoiceClonePolicy.candidates(input,0);assertEquals(2,result.length());assertEquals(10.0,result.getJSONObject(1).getDouble("end")-result.getJSONObject(1).getDouble("start"),0.0)
        assertEquals("日本語",VoiceClonePolicy.candidates(input,2).getJSONObject(0).getString("text"))
    }
    @Test fun simultaneousEventsMergeButAdjacentSpeakersDoNot() {
        val input=JSONArray().put(cue(0.0,3.0,"中文")).put(cue(0.0,3.0,"日本語")).put(cue(3.0,5.0,"A")).put(cue(5.0,7.0,"B"))
        val result=VoiceClonePolicy.candidates(input,2);assertEquals(1,result.length());assertEquals("日本語",result.getJSONObject(0).getString("text"))
        assertEquals(result.getJSONObject(0).getString("key"),VoiceClonePolicy.candidates(input,2).getJSONObject(0).getString("key"))
    }
    @Test fun decimalTimestampSubtractionDoesNotDropAnExactThreeSecondSubtitle() {
        val rows=VoiceClonePolicy.candidates(JSONArray().put(cue(123.456,126.456,"保留三秒片段")),0)
        assertEquals(1,rows.length())
    }
    @Test fun customVoiceDoesNotChangeTargetLanguageAndUnknownIdsStayInvalid() {
        val id="custom:12345678-1234-1234-1234-123456789abc"
        for(language in NarrationPolicy.languages) {
            val config=NarrationPolicy.Config.parse(JSONObject().put("voice_override",id).put("language",language).toString())
            assertEquals(id,config.voice(language));assertEquals(language,config.language)
        }
        assertThrows(IllegalArgumentException::class.java){NarrationPolicy.Config.parse("{\"voice_override\":\"custom:../escape\"}")}
    }
}
