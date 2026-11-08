package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class CastMirrorLeaseTest {
    @Test fun onlyOneProtocolCanOwnTheRotationSurfaces() {
        val lease = CastMirrorLease()
        val start = CountDownLatch(1); val done = CountDownLatch(64); val wins = AtomicInteger()
        val pool = Executors.newFixedThreadPool(8)
        repeat(64) { index -> pool.execute { start.await(); if (lease.claim(if (index % 2 == 0) "AirPlay" else "Miracast") != null) wins.incrementAndGet(); done.countDown() } }
        start.countDown(); assertTrue(done.await(3, java.util.concurrent.TimeUnit.SECONDS)); pool.shutdownNow()
        assertEquals(1, wins.get())
        val owner = lease.current!!
        assertTrue(lease.release(owner.protocol, owner.epoch))
        val next = lease.claim(if (owner.protocol == "AirPlay") "Miracast" else "AirPlay")!!
        assertFalse(lease.release(owner.protocol, owner.epoch))
        assertTrue(lease.matches(next.protocol, next.epoch))
    }
    @Test fun audioSpecificConfigPreservesAirplayAndAddsTheAdvertisedMiracastMode() {
        assertArrayEquals(byteArrayOf(0x12, 0x10), MirrorAudioFormat.aacConfig(4, 1024, 44100, 2))
        assertArrayEquals(byteArrayOf(0x12, 0x14), MirrorAudioFormat.aacConfig(4, 960, 44100, 2))
        assertArrayEquals(byteArrayOf(0xf8.toByte(), 0xe8.toByte(), 0x50, 0), MirrorAudioFormat.aacConfig(8, 480, 44100, 2))
        assertArrayEquals(byteArrayOf(0xf8.toByte(), 0xe8.toByte(), 0x40, 0), MirrorAudioFormat.aacConfig(8, 512, 44100, 2))
        assertArrayEquals(byteArrayOf(0x11, 0x90.toByte()), MirrorAudioFormat.aacConfig(4, 1024, 48000, 2))
    }
    @Test fun lostVideoWaitsForANewKeyframeAndDoesNotReplayTheOldGop() {
        val queue = AirplayPackets()
        val key = AirplayPackets.Packet(true, byteArrayOf(0,0,1,0x65,1), 1, 264)
        assertTrue(queue.offer(key)); queue.discontinuity(true)
        assertFalse(queue.restartVideo())
        assertFalse(queue.offer(key.copy(data = byteArrayOf(0,0,1,0x41,1))))
        assertTrue(queue.offer(key.copy(ns = 2)))
        assertTrue(queue.offer(AirplayPackets.Packet(false, byteArrayOf(1,2,3,4), 3, 0)))
        queue.discontinuity(false)
        assertNull(queue.take(false)); assertNotNull(queue.take(true))
    }
}
