package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.util.ArrayDeque

class AnimatedPhotoDepthTest {
    private class Fixture {
        val jobs = ArrayDeque<Runnable>()
        var current = AnimatedPhotoDepth.Identity(1, 0, 0)
        var captures = 0
        var opens = 0
        var closes = 0
        var alive = false
        var fail = false
        var action: (() -> Unit)? = null
        val runs = mutableListOf<Pair<Boolean, Int>>()
        val depth = AnimatedPhotoDepth({ rgb, _, _ ->
            captures++; rgb.clear(); repeat(12) { rgb.putFloat(current.frame.toFloat()) }; rgb.clear()
            AnimatedPhotoDepth.Input(current, intArrayOf(0, 0, 2, 2))
        }, 2, 2, object : AnimatedPhotoDepth.Backend {
            override fun open() { opens++; alive = true }
            override fun process(rgb: ByteBuffer, rect: IntArray, reset: Boolean, step: Int): ByteArray {
                assertTrue(alive); assertEquals(current.frame.toFloat(), rgb.getFloat(0), 0f)
                runs.add(reset to step); action?.invoke()
                if (fail) error("inference failure")
                return ByteArray(16) { 1 }
            }
            override fun close() { if (alive) { alive = false; closes++ } }
        }, { jobs.addLast(it) })
        fun show(frame: Long, pts: Long, loop: Long = 0) {
            current = AnimatedPhotoDepth.Identity(frame, pts, loop); depth.present(current)
        }
        fun drain() { var n = 0; while (jobs.isNotEmpty()) { check(n++ < 100); jobs.removeFirst().run() } }
        fun close() { depth.close(); drain(); assertFalse(alive) }
    }

    @Test fun motionUsesNewInputsAndTheExisting28msSourceTimePolicy() {
        val f = Fixture()
        try {
            f.show(1, 0); f.drain(); assertEquals("ready", f.depth.status().getString("state"))
            f.show(2, 27_999); assertTrue(f.jobs.isEmpty())
            f.show(3, 28_000); f.drain()
            assertEquals(listOf(true to 1, false to 2), f.runs)
            assertEquals(3L, f.depth.status().getLong("frame_id"))
            assertEquals(1, f.opens); assertEquals(2, f.captures)
            repeat(100) { f.depth.present(f.current) }; assertTrue(f.jobs.isEmpty())
        } finally { f.close() }
        assertEquals(1, f.closes)
    }

    @Test fun newestDisplayedFrameReplacesPendingWorkWithoutAccumulatingPixelBuffers() {
        val f = Fixture()
        try {
            for (i in 1L..1000L) f.show(i, i * 30_000)
            assertEquals(1, f.jobs.size); assertEquals(0, f.captures)
            f.drain(); assertEquals(1, f.captures); assertEquals(1000L, f.depth.status().getLong("frame_id"))
            f.action = { for (i in 1002L..2000L) f.show(i, i * 30_000); f.action = null }
            f.show(1001, 1001 * 30_000L); f.drain()
            assertEquals(3, f.captures); assertEquals(2000L, f.depth.status().getLong("frame_id"))
        } finally { f.close() }
    }

    @Test fun loopClearsTheOldMapAndResetsTemporalHistory() {
        val f = Fixture()
        try {
            f.show(1, 0); f.drain(); val old = f.depth.status().getLong("token")
            f.show(2, 0, 1)
            assertEquals("preparing", f.depth.status().getString("state")); assertTrue(f.depth.pixels(old).isEmpty())
            f.drain(); assertEquals(listOf(true to 1, true to 1), f.runs)
            assertEquals(1L, f.depth.status().getLong("loop"))
        } finally { f.close() }
    }

    @Test fun aLoopDuringInferenceCannotPublishThePreviousScenesDepth() {
        val f = Fixture()
        try {
            f.action = { f.show(2, 0, 1); f.action = null }
            f.show(1, 0); f.jobs.removeFirst().run()
            assertEquals(0L, f.depth.status().getLong("token"))
            f.drain(); assertEquals(1L, f.depth.status().getLong("updates")); assertEquals(1L, f.depth.status().getLong("loop"))
        } finally { f.close() }
    }

    @Test fun closeDuringInferenceRejectsLateResultsAndReleasesTheModel() {
        val f = Fixture(); f.action = { f.depth.close() }; f.show(1, 0); f.drain()
        assertEquals(0L, f.depth.status().getLong("token")); assertEquals(1, f.closes)
        f.show(2, 30_000); assertTrue(f.jobs.isEmpty()); f.close(); assertEquals(1, f.closes)
    }

    @Test fun closeBeforeWorkerStartsDoesNotOpenTheModel() {
        val f = Fixture(); f.show(1, 0); f.close(); assertEquals(0, f.opens); assertEquals(0, f.captures)
    }

    @Test fun failureClearsDepthAndStopsInferenceWithoutOwningTheAnimationDecoder() {
        val f = Fixture()
        try {
            f.show(1, 0); f.drain(); val old = f.depth.status().getLong("token")
            f.fail = true; f.show(2, 30_000); f.drain()
            assertEquals("failed", f.depth.status().getString("state")); assertTrue(f.depth.pixels(old).isEmpty())
            f.show(3, 60_000); assertTrue(f.jobs.isEmpty()); assertEquals(1, f.closes)
        } finally { f.close() }
    }
}
