package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class ComicSpeechPrefetchTest {
    private fun request(id: String)=ComicSpeechPrefetch.Request(id,"今天也去教會嗎？","zh","Xiaoyu")
    @Test fun pageTurnRetainsCompletedAudioButCancelsTheUnfinishedNextBuffer(){
        val backend=FakeNarrationBackend()
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        val cache=ComicSpeechPrefetch(ComicNarrationSession(SharedNarrationEngine(backend)),{intArrayOf()},{})
        try {
            val ready=cache.prepare(request("ready"),false);ready.read({true}){}
            backend.hook={if(it==0){entered.countDown();check(release.await(3,TimeUnit.SECONDS))}}
            val unfinished=cache.prepare(request("unfinished"),false);assertTrue(entered.await(3,TimeUnit.SECONDS))
            cache.retainCompleted();assertTrue(unfinished.failed);assertTrue(cache.ready("ready"))
            assertEquals(1,cache.readyCount(listOf("ready","unfinished","other")))
            assertSame(ready,cache.prepare(request("ready"),true))
            release.countDown();ready.read({true}){}
            cache.clear();assertFalse(cache.ready("ready"))
        } finally {release.countDown();cache.close()}
    }
    @Test fun completedAudioReplaysWithoutAnotherSynthesisAndClearInvalidatesIt(){
        val backend=FakeNarrationBackend();val runtime=SharedNarrationEngine(backend)
        val cache=ComicSpeechPrefetch(ComicNarrationSession(runtime),{intArrayOf()},{})
        try {
            val buffer=cache.prepare(request("a"),false);var samples=0
            buffer.read({true}){samples+=it.size}
            assertTrue(samples>0);assertTrue(cache.ready("a"));val count=backend.syntheses
            assertSame(buffer,cache.prepare(request("a"),true));buffer.read({true}){}
            assertEquals(count,backend.syntheses);cache.clear();assertEquals(0 to 0,cache.snapshot())
            assertThrows(IllegalStateException::class.java){buffer.read({true}){}}
        } finally {cache.close()}
    }
    @Test fun pointedBubblePreemptsUnconsumedBackgroundWork(){
        val backend=FakeNarrationBackend();val runtime=SharedNarrationEngine(backend)
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        backend.hook={if(backend.syntheses==1&&it==0){entered.countDown();check(release.await(3,TimeUnit.SECONDS))}}
        val cache=ComicSpeechPrefetch(ComicNarrationSession(runtime),{intArrayOf()},{})
        try {
            val old=cache.prepare(request("old"),false);assertTrue(entered.await(3,TimeUnit.SECONDS))
            val pointed=cache.prepare(request("pointed"),true);release.countDown();pointed.read({true}){}
            assertTrue(old.failed);assertTrue(pointed.complete);assertTrue(cache.ready("pointed"))
        } finally {release.countDown();cache.close()}
    }
    @Test fun memoryBudgetAndMissingEosNeverProduceAReusablePartialBuffer(){
        for(eos in listOf(true,false)){
            val backend=FakeNarrationBackend();backend.eos=eos
            val cache=ComicSpeechPrefetch(ComicNarrationSession(SharedNarrationEngine(backend)),{intArrayOf()},{},if(eos)100 else 1024*1024)
            try {
                val buffer=cache.prepare(request("a"),false)
                assertThrows(IllegalStateException::class.java){buffer.read({true}){}}
                assertFalse(cache.ready("a"));assertTrue(buffer.failed)
            } finally {cache.close()}
        }
    }
    @Test fun cancelledPlaybackReaderCannotHoldUpTheNextPointedBubble(){
        val backend=FakeNarrationBackend();val entered=CountDownLatch(1);val release=CountDownLatch(1)
        backend.hook={if(backend.syntheses==1&&it==0){entered.countDown();check(release.await(3,TimeUnit.SECONDS))}}
        val cache=ComicSpeechPrefetch(ComicNarrationSession(SharedNarrationEngine(backend)),{intArrayOf()},{})
        var reader: Thread?=null
        try {
            val old=cache.prepare(request("old"),false);assertTrue(entered.await(3,TimeUnit.SECONDS))
            reader=Thread {assertThrows(IllegalStateException::class.java){old.read({true}){}}}.also {it.start()}
            val deadline=System.nanoTime()+1_000_000_000
            while(old.readers==0&&System.nanoTime()<deadline)Thread.yield()
            assertEquals(1,old.readers)
            val next=cache.prepare(request("next"),true)
            assertTrue(old.failed);release.countDown();next.read({true}){};assertTrue(next.complete)
        } finally {release.countDown();cache.close();reader?.join(3000)}
    }
}
