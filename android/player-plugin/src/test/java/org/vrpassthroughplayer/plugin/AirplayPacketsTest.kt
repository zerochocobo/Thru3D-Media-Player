package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class AirplayPacketsTest {
    private fun packet(vararg data: Int) = AirplayPackets.Packet(true, data.map { it.toByte() }.toByteArray(), 1_000_000, 264)
    @Test fun rotationReplaysTheLatestVideoGopAndKeepsPendingAudioOrdered() {
        val queue = AirplayPackets(128)
        queue.offer(packet(0,0,1,0x67,1,0,0,1,0x68,1))
        val key = packet(0,0,1,0x65,1)
        val next = packet(0,0,1,0x41,2).copy(ns = 2_000_000)
        val firstAudio = AirplayPackets.Packet(false, byteArrayOf(1), 1_500_000, 8)
        val secondAudio = firstAudio.copy(data = byteArrayOf(2), ns = 2_500_000)
        queue.offer(key); queue.offer(firstAudio); queue.offer(next); queue.offer(secondAudio)
        assertSame(key, queue.take(true))
        assertTrue(queue.restartVideo())
        assertSame(key, queue.take(true)); assertSame(next, queue.take(true)); assertNull(queue.take(true))
        assertSame(firstAudio, queue.take(false)); assertSame(secondAudio, queue.take(false)); assertNull(queue.take(false))
        assertTrue(queue.retainedBytes() <= 256)
    }
    @Test fun rotationWithAnOversizedGopWaitsForTheNextKeyframe() {
        val queue = AirplayPackets(16)
        queue.offer(packet(0,0,1,0x65,1))
        repeat(3) { queue.offer(packet(0,0,1,0x41,it)) }
        assertFalse(queue.restartVideo()); assertNull(queue.take(true))
        assertFalse(queue.offer(packet(0,0,1,0x41,4)))
        val key = packet(0,0,1,0x65,5)
        assertTrue(queue.offer(key)); assertSame(key, queue.take(true)); assertTrue(queue.retainedBytes() <= 32)
    }
    @Test fun sleepRetainsTheNewestGopAndConfigurationWithoutRetainingAudio() {
        val queue = AirplayPackets(128)
        queue.offer(packet(0,0,1,0x67,1,0,0,1,0x68,1))
        val key = packet(0,0,1,0x65,1)
        val predicted = packet(0,0,1,0x41,2).copy(ns = 2_000_000)
        queue.offer(key); queue.offer(predicted)
        while (queue.take() != null) { }
        queue.park()
        assertTrue(queue.videoReady()); assertTrue(queue.config.isNotEmpty()); assertNull(queue.take())
        assertFalse(queue.offer(AirplayPackets.Packet(false, byteArrayOf(1), 3_000_000, 8)))
        val newest = key.copy(ns = 4_000_000)
        assertTrue(queue.offer(newest)); assertTrue(queue.retainedBytes() <= 256)
        assertEquals(4_000_000, queue.resume())
        assertSame(newest, queue.take(true)); assertNull(queue.take(true))
        queue.clear()
        assertFalse(queue.videoReady()); assertEquals(0, queue.retainedBytes()); assertEquals(0, queue.resume())
    }
    @Test fun oversizedSleepingGopWaitsForAFreshKeyframeWithinItsMemoryBound() {
        val queue = AirplayPackets(32)
        queue.offer(packet(0,0,1,0x67,1,0,0,1,0x68,1))
        queue.offer(packet(0,0,1,0x65,1)); queue.park()
        repeat(100) { queue.offer(packet(0,0,1,0x41,it)); assertTrue(queue.retainedBytes() <= 64) }
        assertFalse(queue.videoReady())
        val fresh = packet(0,0,1,0x65,2).copy(ns = 10_000_000)
        queue.offer(fresh)
        assertTrue(queue.videoReady()); assertEquals(10_000_000, queue.resume()); assertSame(fresh, queue.take(true))
    }
    @Test fun blockedAudioDoesNotPreventDrainingVideoAndKeepsBothStreamsOrdered() {
        val queue = AirplayPackets()
        val key = packet(0,0,1,0x65,1)
        val next = packet(0,0,1,0x41,2)
        val audio1 = AirplayPackets.Packet(false, byteArrayOf(1), 1_000_000, 8)
        val audio2 = audio1.copy(data = byteArrayOf(2), ns = 2_000_000)
        queue.offer(key); queue.offer(audio1); queue.offer(next); queue.offer(audio2)
        assertSame(key, queue.take(true)); assertSame(next, queue.take(true))
        assertNull(queue.take(true))
        assertEquals(2, queue.sizeBytes())
        assertSame(audio1, queue.take(false)); assertSame(audio2, queue.take(false))
        assertNull(queue.take(false)); assertEquals(0, queue.sizeBytes())
    }
    @Test fun separateSpsAndPpsSurviveUntilTheFirstIdr() {
        val queue = AirplayPackets()
        assertFalse(queue.offer(packet(0,0,0,1,0x67,0x42,0)))
        assertFalse(queue.offer(packet(0,0,1,0x68,1)))
        assertTrue(queue.config.contentEquals(byteArrayOf(0,0,0,1,0x67,0x42,0,0,0,0,1,0x68,1)))
        assertFalse(queue.offer(packet(0,0,1,0x41,1)))
        assertTrue(queue.offer(packet(0,0,1,0x65,1)))
        assertEquals(5, queue.take()!!.data.size)
        assertNull(queue.take())
    }
    @Test fun overflowWaitsForANewKeyframeAndRemainsBounded() {
        val queue = AirplayPackets(16)
        assertTrue(queue.offer(packet(0,0,0,1,0x65,1)))
        assertTrue(queue.offer(packet(0,0,0,1,0x41,1)))
        assertFalse(queue.offer(packet(0,0,0,1,0x41,1)))
        assertEquals(0, queue.sizeBytes())
        assertFalse(queue.offer(packet(0,0,0,1,0x41,1)))
        assertTrue(queue.offer(packet(0,0,0,1,0x65,2)))
        assertTrue(queue.sizeBytes() <= 16)
    }
    @Test fun stopDropsConfigurationAndAudioCannotStartVideo() {
        val queue = AirplayPackets()
        assertFalse(queue.offer(AirplayPackets.Packet(false, byteArrayOf(1), 10, 8)))
        queue.offer(packet(0,0,0,1,0x67,1,0,0,0,1,0x68,2,0,0,1,0x65,3))
        assertTrue(queue.config.isNotEmpty())
        queue.clear()
        assertEquals(0, queue.sizeBytes()); assertTrue(queue.config.isEmpty())
        assertFalse(queue.offer(packet(0,0,1,0x41,1)))
    }
    @Test fun invalidAndUnsupportedPacketsAreRejected() {
        val queue = AirplayPackets(16)
        assertFalse(queue.offer(packet()))
        assertFalse(queue.offer(AirplayPackets.Packet(true, ByteArray(17), 1, 264)))
        assertFalse(queue.offer(AirplayPackets.Packet(true, byteArrayOf(0,0,0,1,0x65), 1, 265)))
        assertTrue(AirplayPackets.nals(byteArrayOf(0,0,0,1)).isEmpty())
        assertTrue(AirplayPackets.nals(byteArrayOf(0,0,1)).isEmpty())
    }
}
