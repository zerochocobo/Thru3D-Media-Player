package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class NarrationPreviewSessionTest {
    @get:Rule val folder=TemporaryFolder()
    private val id="custom:12345678-1234-1234-1234-123456789abc"
    private fun cache(limit: Long=16L*1024*1024)=NarrationPreviewCache(File(folder.root,"saved"),File(folder.root,"temporary"),limit)
    private class Output(private val began: ()->Unit={}) : VoicePreviewStream.Output {
        var samples=0;var done=false
        override fun start()=began()
        override fun write(pcm: FloatArray){samples+=pcm.size}
        override fun finish(samples: Int){check(samples==this.samples);done=true}
        override fun close(){}
    }
    @Test fun switchesStayWarmAndFirstAuditionStartsBeforeGenerationEnds() {
        val backend=FakeNarrationBackend();val runtime=SharedNarrationEngine(backend);val normal=runtime.acquire({true})
        val session=NarrationPreviewSession(runtime,{cache()},{})
        // The first verified clause plays while the next one is still generating.
        val text="你好，很高兴认识你。今天天气很舒服。"
        backend.chunkCount=6
        val began=CountDownLatch(1);backend.hook={if(backend.syntheses==2&&it==4)check(began.await(3,TimeUnit.SECONDS))}
        val output=Output {began.countDown()};var hit=false
        session.play("Xiaoyu","zh",text,intArrayOf(),true,"model",{true},{output},{},{a,_->hit=a},{fail("cache failure")})
        assertFalse(hit);assertTrue(output.done);assertEquals(2,backend.syntheses);assertTrue(output.samples>0)
        backend.hook={}
        session.play("Ava","en","hello",intArrayOf(),true,"model",{true},{Output()},{},{_,_->},{fail("cache failure")})
        session.play("Xiaoyu","zh",text,intArrayOf(),true,"model",{true},{Output()},{},{a,_->hit=a},{fail("cache failure")})
        assertTrue(hit);assertEquals(3,backend.syntheses);assertEquals(1,backend.created)
        session.close();assertEquals(1,backend.live);normal.close();assertEquals(0,backend.live)
    }
    @Test fun persistentHitWorksInANewSessionWithoutLoadingAnyModel() {
        val first=SharedNarrationEngine(FakeNarrationBackend());val session=NarrationPreviewSession(first,{cache()},{})
        session.play(id,"zh","sample",IntArray(592){1},true,"v1",{true},{Output()},{},{_,_->},{fail("cache failure")})
        session.close();first.close()
        val backend=FakeNarrationBackend();val reopened=SharedNarrationEngine(backend);var hit=false
        NarrationPreviewSession(reopened,{cache()},{error("Cache hits must not drain or load TTS")}).use {
            it.play(id,"zh","sample",IntArray(592){1},true,"v1",{true},{Output()},{},{cached,_->hit=cached},{fail("cache failure")})}
        assertTrue(hit);assertEquals(0,backend.created);assertEquals(0,backend.syntheses)
    }
    @Test fun subtitleSampleReplayUsesOnlyTheBoundedTemporaryStore() {
        val backend=FakeNarrationBackend();val runtime=SharedNarrationEngine(backend);var hit=false
        NarrationPreviewSession(runtime,{cache()},{ }).use {session->
            repeat(2){session.play(id,"zh","a subtitle",IntArray(592),false,"v1",{true},{Output()},{},{cached,_->hit=cached},{fail("cache failure")})}}
        assertTrue(hit);assertEquals(1,backend.syntheses)
        assertFalse(File(folder.root,"saved").exists());assertTrue(File(folder.root,"temporary").listFiles()!!.any {it.extension=="pcm"})
    }
    @Test fun aClauseThatNeverEndsIsNeverHeardAndFailsAfterTheBoundedLadder() {
        val backend=FakeNarrationBackend();backend.eos=false;val runtime=SharedNarrationEngine(backend);var started=false
        NarrationPreviewSession(runtime,{cache()},{ }).use {session->
            assertThrows(IllegalStateException::class.java){session.play(id,"zh","sample",IntArray(592),true,"v1",{true},{Output {started=true}},{},{_,_->},{})}}
        assertFalse(started);assertEquals(listOf(false to 0,true to 0,false to 17,true to 17),backend.calls.map {it.second to it.third})
        assertFalse(File(folder.root,"saved").walkTopDown().any {it.isFile})
    }
    @Test fun aRecoveredClausePlaysOnlyItsCompleteRetry() {
        val backend=FakeNarrationBackend();backend.eosFor={_,precision,_->precision};val runtime=SharedNarrationEngine(backend)
        val output=Output();var generation: NarrationPreviewSession.Generation?=null
        NarrationPreviewSession(runtime,{cache()},{ }).use {session->
            session.play(id,"zh","你好，很高兴认识你。",IntArray(592),true,"v1",{true},{output},{},{_,_->},{fail("cache failure")},generationInfo={generation=it})}
        assertTrue(output.done);assertEquals(NarrationPreviewSession.Generation(1,2,1,0),generation)
        val key=NarrationPreviewCache.key(id,"zh","你好，很高兴认识你。","v1",IntArray(592))
        assertEquals(4*30720,cache().find(id,"zh",key,true){true}!!.samples)
    }
    @Test fun aMergedClauseThatNeverEndsIsRetriedAsItsOwnClauses() {
        val backend=FakeNarrationBackend();backend.eosFor={text,_,_->"、" !in text};val runtime=SharedNarrationEngine(backend)
        var generation: NarrationPreviewSession.Generation?=null
        NarrationPreviewSession(runtime,{cache()},{ }).use {session->
            session.play(id,"zh","计划、音乐。",IntArray(592),true,"v1",{true},{Output()},{},{_,_->},{fail("cache failure")},generationInfo={generation=it})}
        assertEquals(listOf("计划。","音乐。"),backend.calls.drop(4).map {it.first})
        assertEquals(NarrationPreviewSession.Generation(1,6,0,1),generation)
    }
    @Test fun previewTextIsSegmentedIntoShortClausesWithoutLosingText() {
        val zh=VoiceClonePreviewText.text("zh")
        assertEquals(listOf("你好，很高兴认识你。","今天天气很舒服。","我们可以聊聊最近的计划。","喜欢的音乐。","也分享一些温暖有趣的想法。"),
            NarrationPreviewSession.segments(zh,"zh"))
        assertEquals(listOf("Hello, it's nice to meet you.","The weather is lovely today.","We can talk about our recent plans and favorite music.",
            "and share some warm, interesting ideas."),NarrationPreviewSession.segments(VoiceClonePreviewText.text("en"),"en"))
        assertEquals(listOf("3.5 euros.","¿Qué?"),NarrationPreviewSession.segments("3.5 euros. ¿Qué?","es"))
        fun letters(value: String)=value.filter {it.isLetterOrDigit()}
        for(language in VoiceClonePreviewText.languages){
            val text=VoiceClonePreviewText.text(language);val segments=NarrationPreviewSession.segments(text,language)
            assertEquals(language,letters(text),letters(segments.joinToString("")))
            assertTrue(language,segments.size>=3)
        }
    }
    @Test fun cancellationNeverCommitsAPartialPersistentSample() {
        val backend=FakeNarrationBackend();val runtime=SharedNarrationEngine(backend);val active=AtomicBoolean(true)
        backend.hook={if(it==2)active.set(false)}
        val session=NarrationPreviewSession(runtime,{cache()},{})
        assertThrows(IllegalStateException::class.java){session.play(id,"zh","sample",IntArray(592),true,"v1",{active.get()},{Output()},{},{_,_->},{})}
        assertFalse(File(folder.root,"saved").walkTopDown().any {it.isFile});session.close();runtime.close()
    }
    @Test fun stoppingPlaybackKeepsAnAlreadyCompletedPersistentSample() {
        val backend=FakeNarrationBackend();val runtime=SharedNarrationEngine(backend);val active=AtomicBoolean(true)
        val stopped=object:VoicePreviewStream.Output {
            override fun start(){}
            override fun write(pcm: FloatArray){}
            override fun finish(samples: Int){active.set(false)}
            override fun close(){}
        }
        NarrationPreviewSession(runtime,{cache()},{ }).use {session->
            assertThrows(IllegalStateException::class.java){session.play(id,"zh","sample",IntArray(592),true,"v1",{active.get()},{stopped},{},{_,_->},{fail("cache failure")})}}
        val key=NarrationPreviewCache.key(id,"zh","sample","v1",IntArray(592))
        assertNotNull(cache().find(id,"zh",key,true){true})
    }
    @Test fun versionsRemainUntilExplicitVoiceDeletionAndTemporaryLruCannotTouchThem() {
        val store=cache(500)
        fun save(voice: String,lang: String,text: String,saved: Boolean): String {
            val key=NarrationPreviewCache.key(voice,lang,text,"model",intArrayOf())
            store.writer(voice,lang,key,saved).use {it.append(FloatArray(200){.25f});it.complete {true}}
            return key
        }
        val old=save(id,"zh","old",true);val updated=save(id,"zh","new",true);val preset=save("Xiaoyu","zh","sample",true)
        repeat(8){save("unsaved-$it","zh","caption-$it",false)}
        assertNotNull(store.find(id,"zh",old,true){true});assertNotNull(store.find(id,"zh",updated,true){true})
        assertTrue(File(folder.root,"temporary").walkTopDown().filter {it.isFile}.sumOf {it.length()}<=500)
        store.deleteVoice(id)
        assertNull(store.find(id,"zh",old,true){true});assertNull(store.find(id,"zh",updated,true){true})
        assertNotNull(store.find("Xiaoyu","zh",preset,true){true})
    }
    @Test fun corruptPersistentAudioIsRejectedWithoutDeletingUserRetainedVersions() {
        val store=cache();val key=NarrationPreviewCache.key(id,"zh","sample","v1",intArrayOf())
        val entry=store.writer(id,"zh",key,true).use {it.append(FloatArray(200){.2f});it.complete {true}}
        entry.file.appendBytes(byteArrayOf(0))
        assertNull(store.find(id,"zh",key,true){true});assertTrue(entry.file.exists())
    }
    @Test fun cacheIdentityIncludesVoiceLanguageTextModelAndCodes() {
        val base=NarrationPreviewCache.key(id,"zh","sample","model",intArrayOf(1))
        assertNotEquals(base,NarrationPreviewCache.key("Xiaoyu","zh","sample","model",intArrayOf(1)))
        assertNotEquals(base,NarrationPreviewCache.key(id,"en","sample","model",intArrayOf(1)))
        assertNotEquals(base,NarrationPreviewCache.key(id,"zh","new","model",intArrayOf(1)))
        assertNotEquals(base,NarrationPreviewCache.key(id,"zh","sample","new",intArrayOf(1)))
        assertNotEquals(base,NarrationPreviewCache.key(id,"zh","sample","model",intArrayOf(2)))
    }
    @Test fun slowPlaybackAppliesBoundedBackpressureAndCancellationStopsTheProducer() {
        val active=AtomicBoolean(true);val blocked=CountDownLatch(1);val release=CountDownLatch(1)
        val output=object:VoicePreviewStream.Output {
            override fun start(){}
            override fun write(pcm: FloatArray){blocked.countDown();check(release.await(3,TimeUnit.SECONDS))}
            override fun finish(samples: Int){}
            override fun close(){release.countDown()}
        }
        val stream=VoicePreviewStream({active.get()},output);val worker=Executors.newSingleThreadExecutor()
        try {
            val task=worker.submit {repeat(30){stream.append(FloatArray(30720))}}
            assertTrue(blocked.await(3,TimeUnit.SECONDS));Thread.sleep(100);assertFalse(task.isDone)
            active.set(false);stream.close()
            assertThrows(java.util.concurrent.ExecutionException::class.java){task.get(3,TimeUnit.SECONDS)}
        } finally {active.set(false);release.countDown();stream.close();worker.shutdownNow()}
    }
    @Test fun existingPersistentAudioIsProcessedOnReplayWithoutRewritingOrLoadingAModel() {
        val store=cache();val key=NarrationPreviewCache.key(id,"zh","你好，很高兴为您服务。","v1",IntArray(592))
        val input=FloatArray(57600){(.1*kotlin.math.sin(2*Math.PI*220*(it/2)/48000)).toFloat()}+
            FloatArray(96000)+FloatArray(76800){(.1*kotlin.math.sin(2*Math.PI*440*(it/2)/48000)).toFloat()}
        val entry=store.writer(id,"zh",key,true).use {it.append(input);it.complete {true}}
        val bytes=entry.file.readBytes();val backend=FakeNarrationBackend();val runtime=SharedNarrationEngine(backend)
        var stats: NarrationRhythm.Stats?=null;val output=Output()
        NarrationPreviewSession(runtime,{store},{error("Cache hit must not prepare a model")}).use {
            it.play(id,"zh","你好，很高兴为您服务。",IntArray(592),true,"v1",{true},{output},{},{hit,_->assertTrue(hit)},{fail("cache error")},{stats=it})}
        assertTrue(output.done);assertTrue(output.samples<input.size);assertEquals(output.samples,stats!!.outputSamples)
        assertTrue(stats!!.removedPauseSamples>0);assertTrue(stats!!.removedDragSamples>0)
        assertEquals(0,backend.created);assertArrayEquals(bytes,entry.file.readBytes())
    }
}
