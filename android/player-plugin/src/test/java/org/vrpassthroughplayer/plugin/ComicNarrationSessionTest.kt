package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class ComicNarrationSessionTest {
    @Test fun kanaChantsAndShortDialogueKeepContextAndNeverLeaveSingleGlyphTails() {
        val chant="さ！し！は！ら！リ！の！"
        assertEquals(listOf(chant),ComicNarrationSession.segments(chant))
        assertEquals("さ、し、は、ら、リ、の!",ComicNarrationSession.spokenText(chant,"ja"))
        assertEquals("さ!し!は!ら!リ!の!",ComicNarrationSession.spokenText(chant,"zh"))
        assertEquals("それは!違う!",ComicNarrationSession.spokenText("それは！違う！","ja"))
        assertEquals("你好。",ComicNarrationSession.spokenText("「你好」","zh"))
        assertEquals(listOf("這個啊！這個！"),ComicNarrationSession.segments("這個啊！這個！"))
        for(n in 25..120){
            val text="字".repeat(n-2)+"！！"
            val chunks=ComicNarrationSession.segments(text)
            assertEquals(text,chunks.joinToString(""))
            assertTrue(chunks.all {it.codePointCount(0,it.length) in 6..24})
        }
    }
    private class Output: VoicePreviewStream.Output {
        var samples=0;var finished=0;var starts=0
        override fun start(){starts++}
        override fun write(pcm: FloatArray){assertTrue(pcm.all {it.isFinite()});samples+=pcm.size}
        override fun finish(samples: Int){assertEquals(this.samples,samples);finished++}
        override fun close(){}
    }
    @Test fun longDialogueAndSurrogatePairsAreNeverTruncatedOrSplit() {
        val text="這就是完整的對話。"+"今天也去教會嗎？".repeat(6)+"𠮷野！"
        val chunks=ComicNarrationSession.segments(text)
        assertEquals(text,chunks.joinToString(""));assertTrue(chunks.all {it.codePointCount(0,it.length)<=24})
        assertTrue(chunks.none {Character.isHighSurrogate(it.last())||Character.isLowSurrogate(it.first())})
        val expanded="Wait for me! ".repeat(30)
        assertEquals(expanded,ComicNarrationSession.segments(expanded).joinToString(""))
        assertThrows(IllegalArgumentException::class.java){ComicNarrationSession.segments("字".repeat(2001))}
    }
    @Test fun presetAndSavedCloneUseTheExistingSingleRuntimeAndStreamingOutput() {
        val backend=FakeNarrationBackend();var forwarded=IntArray(0)
        val runtime=SharedNarrationEngine(object:SharedNarrationEngine.Backend by backend {
            override fun register(handle: Long,voice: String,codes: IntArray){forwarded=codes.copyOf();backend.register(handle,voice,codes)}
        })
        val subtitle=runtime.acquire({true});val reader=ComicNarrationSession(runtime)
        val preset=Output();reader.play("今天也去教會嗎？","zh","Xiaoyu",{error("preset must not load clone codes")},1,{true},{preset})
        val clone="custom:12345678-1234-1234-1234-123456789abc";var loads=0
        val output=Output();reader.play("這是已保存的克隆音色。","zh",clone,{loads++;IntArray(592){it}},2,{true},{output})
        assertEquals(1,backend.created);assertEquals(listOf(clone),backend.registered);assertEquals(1,loads)
        assertArrayEquals(IntArray(592){it},forwarded)
        assertTrue(preset.samples>0&&output.samples>0);assertEquals(1,output.finished)
        reader.close();assertEquals(1,backend.live);subtitle.close();assertEquals(0,backend.live)
    }
    @Test fun PageCancellationRejectsObsoletePcmAndDoesNotFinishPlayback() {
        val backend=FakeNarrationBackend();val runtime=SharedNarrationEngine(backend);val reader=ComicNarrationSession(runtime)
        var active=true;backend.hook={active=false};val output=Output()
        assertThrows(IllegalStateException::class.java){reader.play("翻頁前的這段對話。","zh","Xiaoyu",{intArrayOf()},1,{active},{output})}
        assertEquals(0,output.samples);assertEquals(0,output.finished);reader.close();runtime.close()
    }
    @Test fun missingEosFailsInsteadOfTreatingTruncationAsACompleteBubble() {
        val backend=FakeNarrationBackend();backend.eos=false;val runtime=SharedNarrationEngine(backend);val reader=ComicNarrationSession(runtime)
        val output=Output()
        assertThrows(IllegalStateException::class.java){reader.play("這是需要完整讀完的一段對話。","zh","Xiaoyu",{intArrayOf()},1,{true},{output})}
        assertEquals(0,output.finished);reader.close();runtime.close()
    }
}
