package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

internal class FakeNarrationBackend: SharedNarrationEngine.Backend {
    var created=0;var destroyed=0;var live=0;var maximumLive=0;var syntheses=0
    val registered=ArrayList<String>()
    val token=AtomicLong()
    var hook: (Int)->Unit={}
    var eos=true
    var chunkCount=4
    var createHook: ()->Unit={}
    override fun create(active: ()->Boolean,progress: (String,Long,Long)->Unit): Long {
        createHook();created++;live++;maximumLive=maxOf(maximumLive,live);return created.toLong()
    }
    override fun destroy(handle: Long){destroyed++;live--}
    override fun cancel(handle: Long,token: Long){this.token.set(token)}
    override fun register(handle: Long,voice: String,codes: IntArray){registered+=voice}
    val calls=ArrayList<Triple<String,Boolean,Int>>()
    var eosFor: (String,Boolean,Int)->Boolean={_,_,_->eos}
    override fun synthesize(handle: Long,text: String,voice: String,token: Long,frames: Int,precision: Boolean,sink: NarrationNative.Sink,randomSkip: Int): String {
        syntheses++;calls+=Triple(text,precision,randomSkip)
        for(i in 0 until chunkCount){hook(i);if(this.token.get()!=token||!sink.onChunk(token,FloatArray(30720){.25f}))return "{\"cancelled\":true}"}
        return "{\"eos\":${eosFor(text,precision,randomSkip)},\"cancelled\":false}"
    }
}
class SharedNarrationEngineTest {
    private val sink=object:NarrationNative.Sink {override fun onChunk(epoch: Long,pcm: FloatArray)=true}
    @Test fun normalAndManyAuditionsShareOneInstanceUntilTheLastOwnerLeaves() {
        val backend=FakeNarrationBackend();val runtime=SharedNarrationEngine(backend)
        val normal=runtime.acquire({true});val preview=runtime.acquire({true})
        repeat(6){runtime.synthesize(preview,"test","custom:12345678-1234-1234-1234-123456789abc",it.toLong(),250,false,{true},{intArrayOf(it)},sink)}
        assertEquals(1,backend.created);assertEquals(1,backend.maximumLive)
        preview.close();assertEquals(1,backend.live);normal.ensure({true});assertEquals(1,backend.created)
        normal.close();assertEquals(0,backend.live);assertEquals(1,backend.destroyed)
    }
    @Test fun onlyRealEncodingReleasesWeightsAndBothOwnersSeeTheReplacement() {
        val backend=FakeNarrationBackend();val runtime=SharedNarrationEngine(backend)
        val normal=runtime.acquire({true});val preview=runtime.acquire({true})
        runtime.encoding({true}){assertEquals(0,backend.live);assertEquals(0L,normal.handle)}
        preview.ensure({true});normal.ensure({true})
        assertEquals(2,backend.created);assertEquals(preview.handle,normal.handle);assertEquals(1,backend.maximumLive)
        runtime.close();assertEquals(0,backend.live)
    }
    @Test fun cancellingAnInactiveOwnerCannotCancelAnotherOwnersAudition() {
        val backend=FakeNarrationBackend();val runtime=SharedNarrationEngine(backend)
        val normal=runtime.acquire({true});val preview=runtime.acquire({true})
        val entered=CountDownLatch(1);val proceed=CountDownLatch(1)
        backend.hook={if(it==0){entered.countDown();check(proceed.await(3,TimeUnit.SECONDS))}}
        val worker=Executors.newSingleThreadExecutor()
        try {
            val task=worker.submit<String>{runtime.synthesize(preview,"test","Xiaoyu",7,250,false,{true},{intArrayOf()},sink)}
            assertTrue(entered.await(3,TimeUnit.SECONDS));val before=backend.token.get();normal.cancel();assertEquals(before,backend.token.get())
            preview.cancel();assertNotEquals(before,backend.token.get());proceed.countDown()
            assertTrue(JSONObject(task.get(3,TimeUnit.SECONDS)).optBoolean("cancelled"))
        } finally {proceed.countDown();worker.shutdownNow();runtime.close()}
    }
    @Test fun cancelledCreationDoesNotLeakAHandleOrAnOwner() {
        val backend=FakeNarrationBackend();val runtime=SharedNarrationEngine(backend);var active=true
        backend.createHook={active=false}
        assertThrows(IllegalStateException::class.java){runtime.acquire({active})}
        assertEquals(0,backend.live);backend.createHook={};runtime.acquire({true}).close();assertEquals(0,backend.live)
    }
    @Test fun clientEpochsArePreservedWhileNativeTokensNeverCollide() {
        val backend=FakeNarrationBackend();val runtime=SharedNarrationEngine(backend)
        val a=runtime.acquire({true});val b=runtime.acquire({true});val epochs=ArrayList<Long>();val native=ArrayList<Long>()
        backend.hook={if(it==0)native+=backend.token.get()}
        val collect=object:NarrationNative.Sink {override fun onChunk(epoch: Long,pcm: FloatArray): Boolean {epochs+=epoch;return true}}
        runtime.synthesize(a,"a","Xiaoyu",1,250,false,{true},{intArrayOf()},collect)
        runtime.synthesize(b,"b","Ava",1,250,false,{true},{intArrayOf()},collect)
        assertTrue(epochs.all {it==1L});assertNotEquals(native[0],native[1]);runtime.close()
    }
    @Test fun theSameImmutableVoiceDoesNotReloadItsCodesForEverySubtitle() {
        val backend=FakeNarrationBackend();val runtime=SharedNarrationEngine(backend);val lease=runtime.acquire({true});var loads=0
        repeat(4){runtime.synthesize(lease,"test","custom:12345678-1234-1234-1234-123456789abc",1,250,false,{true},{loads++;IntArray(592)},sink)}
        assertEquals(1,loads);assertEquals(1,backend.registered.size);runtime.close()
    }
    @Test fun anotherOwnerCannotReloadTtsWhileTheEncoderIsStillAlive() {
        val backend=FakeNarrationBackend();val runtime=SharedNarrationEngine(backend);val normal=runtime.acquire({true});val preview=runtime.acquire({true})
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val workers=Executors.newFixedThreadPool(2)
        try {
            val encoder=workers.submit {runtime.encoding({true}){entered.countDown();check(release.await(3,TimeUnit.SECONDS))}}
            assertTrue(entered.await(3,TimeUnit.SECONDS))
            val waiting=workers.submit {preview.ensure({true})};Thread.sleep(80)
            assertFalse(waiting.isDone);assertEquals(0,backend.live)
            release.countDown();encoder.get(3,TimeUnit.SECONDS);waiting.get(3,TimeUnit.SECONDS)
            assertEquals(2,backend.created);assertEquals(1,backend.maximumLive);assertEquals(normal.handle,preview.handle)
        } finally {release.countDown();workers.shutdownNow();runtime.close()}
    }
}
