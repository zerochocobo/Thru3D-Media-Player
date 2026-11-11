package org.vrpassthroughplayer.plugin

import java.io.File
import java.nio.file.Files
import java.util.ArrayDeque
import java.util.concurrent.AbstractExecutorService
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AnimatedPhotoSessionTest {
    private class Work: AbstractExecutorService() {
        val jobs=ArrayDeque<Runnable>();var stopped=false
        override fun execute(task: Runnable){check(!stopped);jobs.addLast(task)}
        override fun shutdown(){stopped=true}
        override fun shutdownNow(): MutableList<Runnable>{stopped=true;return jobs.toMutableList().also {jobs.clear()}}
        override fun isShutdown()=stopped
        override fun isTerminated()=stopped&&jobs.isEmpty()
        override fun awaitTermination(timeout: Long,unit: TimeUnit)=isTerminated
        fun drain(){var n=0;while(jobs.isNotEmpty()){check(n++<100);jobs.removeFirst().run()}}
    }
    private class Backend(val frameCount: Int=3,val plays: Long=1): PhotoAnimationBackend {
        var frame=0;var serial=0L;var resets=0;var closes=0;var maxLive=0;var failAt=-1
        var failureMessage="decode failure"
        var onNext: (() -> Unit)?=null
        var onInput: (() -> Unit)?=null
        val live=mutableSetOf<Long>()
        override fun open(path: String)=1L
        override fun info(id: Long)=longArrayOf(3,2,2,frameCount.toLong(),plays,1,1,0)
        override fun next(id: Long,check: Runnable): LongArray {
            check.run();if(frame==failAt)error(failureMessage)
            if(frame++>=frameCount)return longArrayOf(0,0,0,0)
            val token=++serial;live.add(token);maxLive=maxOf(maxLive,live.size)
            onNext?.invoke();return longArrayOf(token,2,2,10000)
        }
        override fun reset(id: Long){resets++;frame=0}
        override fun pixels(token: Long)=if(token in live)ByteArray(16) else null
        override fun depthInput(token: Long,input: java.nio.ByteBuffer,width: Int,height: Int): IntArray? {
            if(token !in live)return null
            onInput?.invoke()
            input.clear();repeat(width*height*3){input.putFloat(token.toFloat())};input.clear()
            return intArrayOf(0,0,width,height)
        }
        override fun upload(token: Long,texture: Int,mipmaps: Boolean)=token in live
        override fun releaseFrame(token: Long){assertTrue("Frame lease released exactly once",live.remove(token))}
        override fun close(id: Long){closes++}
    }
    private class Fixture(val backend: Backend=Backend()) {
        val directory=Files.createTempDirectory(File("build/test-temp").apply {mkdirs()}.toPath(),"animation-").toFile()
        val source=PhotoSource(File(directory,"source").apply {writeText("fixture")})
        val work=Work();var time=0L
        val session=AnimatedPhotoSession(source,backend,work){time}
        fun poll()=JSONObject(session.poll())
        fun close(){session.close();work.drain();source.release();assertFalse(directory.exists());assertTrue(backend.live.isEmpty())}
    }
    @Test fun prefetchIsBoundedAndDisplayedFramesStayLeased(){val f=Fixture()
        try{f.work.drain();assertEquals(2,f.backend.live.size)
            assertEquals(1,f.poll().getLong("token"));f.work.drain();assertEquals(3,f.backend.live.size)
            f.time=10000;assertEquals(2,f.poll().getLong("token"));assertFalse(f.session.upload(1,7,false))
            assertTrue(f.session.upload(2,7,false));f.work.drain();assertTrue(f.backend.maxLive<=3)
        }finally {f.close()};assertEquals(1,f.backend.closes)}
    @Test fun pauseKeepsRemainingDurationAndDoesNotDecodeAhead(){val f=Fixture()
        try{f.work.drain();f.poll();f.time=5000;f.session.pause(true);f.work.drain()
            f.time=105000;assertEquals(1,f.poll().getLong("token"));assertFalse(f.poll().getBoolean("ended"))
            f.session.pause(false);f.time=109999;assertEquals(1,f.poll().getLong("token"))
            f.time=110000;assertEquals(2,f.poll().getLong("token"))
        }finally {f.close()}}
    @Test fun finitePlayCountEndsOnLastFrameWithoutExtraLoop(){val f=Fixture(Backend(2,2))
        try{f.work.drain();assertEquals(1,f.poll().getLong("token"));f.work.drain()
            for(i in 1..3){f.time=i*10000L;assertEquals(i+1L,f.poll().getLong("token"));f.work.drain()}
            f.time=40000;assertTrue(f.poll().getBoolean("ended"));assertEquals(1,f.backend.resets);assertEquals(4,f.backend.serial)
        }finally {f.close()}}
    @Test fun infiniteLoopAndCloseRejectStaleUploads(){val f=Fixture(Backend(1,0))
        f.work.drain();f.poll();f.work.drain();f.time=30000;f.poll();f.work.drain();assertFalse(f.poll().getBoolean("ended"))
        f.session.close();f.work.drain();assertEquals("",f.session.poll());assertFalse(f.session.upload(1,7,false))
        f.source.release();assertTrue(f.backend.live.isEmpty());assertFalse(f.directory.exists())}
    @Test fun cancellationDuringDecodeReleasesUnpublishedFrame(){val f=Fixture()
        f.backend.onNext={f.session.close()};f.work.drain();assertTrue(f.backend.live.isEmpty());assertEquals(1,f.backend.closes)
        assertTrue("Owner still holds source",f.source.file.isFile);f.source.release();assertFalse(f.directory.exists())}
    @Test fun failureRetainsOnlyValidFrameAndReportsFailure(){val f=Fixture(Backend().apply {failAt=1})
        try{f.work.drain();val state=f.poll();assertTrue(state.getBoolean("failed"));assertEquals(1,state.getLong("token"))
            assertEquals(1,f.backend.live.size)
        }finally {f.close()}}
    @Test fun memoryPressurePreservesLastGoodFrameAndReportsTheCause(){val f=Fixture(Backend().apply {
        failAt=1;failureMessage="PHOTO_OUT_OF_MEMORY"
    })
        try{f.work.drain();val state=f.poll();assertTrue(state.getBoolean("failed"))
            assertEquals("PHOTO_OUT_OF_MEMORY",state.getString("error"));assertEquals(1,state.getLong("token"))
        }finally {f.close()}}
    @Test fun longStallBoundsCatchupAndRebasesClock(){val f=Fixture(Backend(100,0))
        try{f.work.drain();f.poll();f.work.drain();f.time=5000000
            val token=f.poll().getLong("token");assertEquals(3,token);f.work.drain()
            assertEquals(token,f.poll().getLong("token"));assertTrue(f.backend.maxLive<=3)
            f.time+=10000;assertEquals(4,f.poll().getLong("token"))
        }finally {f.close()}}
    @Test fun depthSamplesTheDisplayedLeaseAndUsesSourceTimingAcrossLoops(){val f=Fixture(Backend(2,0))
        try {
            val rgb=java.nio.ByteBuffer.allocateDirect(48).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            assertNull(f.session.depthInput(rgb,2,2));f.work.drain();f.poll();f.work.drain()
            var input=f.session.depthInput(rgb,2,2)!!
            assertEquals(AnimatedPhotoDepth.Identity(1,0,0),input.identity);assertEquals(1f,rgb.getFloat(0),0f)
            f.time=10000;f.poll();f.work.drain();input=f.session.depthInput(rgb,2,2)!!
            assertEquals(AnimatedPhotoDepth.Identity(2,10000,0),input.identity);assertEquals(2f,rgb.getFloat(0),0f)
            f.time=20000;f.poll();input=f.session.depthInput(rgb,2,2)!!
            assertEquals(AnimatedPhotoDepth.Identity(3,0,1),input.identity);assertEquals(3f,rgb.getFloat(0),0f)
            f.session.pause(true);f.time+=100000;f.poll()
            assertEquals(input.identity,f.session.depthInput(rgb,2,2)!!.identity)
        }finally {f.close()}}
    @Test fun backgroundSamplingNeverHoldsThePresentationLock(){val f=Fixture()
        val entered=java.util.concurrent.CountDownLatch(1);val resume=java.util.concurrent.CountDownLatch(1)
        val done=java.util.concurrent.CountDownLatch(1)
        f.work.drain();f.poll()
        f.backend.onInput={entered.countDown();check(resume.await(5,TimeUnit.SECONDS))}
        val sampler=Thread {try {f.session.depthInput(java.nio.ByteBuffer.allocateDirect(48),2,2)}finally {done.countDown()}}
        sampler.start()
        try {
            assertTrue(entered.await(5,TimeUnit.SECONDS))
            // Closing from a different thread must finish even while sampling is still active.
            val closed=java.util.concurrent.CountDownLatch(1)
            val closer=Thread {f.session.close();closed.countDown()};closer.start()
            assertTrue("XR presentation/close cannot wait for model-input sampling",closed.await(2,TimeUnit.SECONDS))
            assertEquals(1L,done.count)
        }finally {resume.countDown();sampler.join(5000);f.close()}
    }
}
