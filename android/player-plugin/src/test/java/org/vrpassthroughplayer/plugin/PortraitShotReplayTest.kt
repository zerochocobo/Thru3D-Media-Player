package org.vrpassthroughplayer.plugin

import java.io.File
import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Optional replay of local, non-distributed acceptance media. Decode at native 48x32 RGBA,
 * preserving frame rate, into PORTRAIT_SHOT_FIXTURES/{source,portrait_cuts}.rgba. */
class PortraitShotReplayTest {
    @Test fun continuousMovementAndSameSetEdits() {
        val path = System.getenv("PORTRAIT_SHOT_FIXTURES")
        assumeTrue("Local device fixtures not supplied", !path.isNullOrBlank())
        val expected = mapOf("source" to emptyList<Double>(), "portrait_cuts" to listOf(8.0,16.0,24.033333))
        for ((name, times) in expected) {
            val detector = PortraitShotDetector()
            val bytes = ByteArray(48*32*4)
            val found = mutableListOf<Double>()
            File(path!!,"$name.rgba").inputStream().buffered().use { input ->
                var index = 0
                while (true) {
                    val n = input.readNBytes(bytes,0,bytes.size)
                    if (n == 0) break
                    assertEquals(bytes.size,n)
                    val result = detector.observe(ByteBuffer.wrap(bytes), index*1_000_000L/30)
                    if (index>0 && result.cut) { found += index/30.0; println("$name frame=$index $result") }
                    index++
                }
                assertTrue("Replay needs more than a short synthetic sample",index>900)
            }
            assertEquals("$name cuts: $found",times.size,found.size)
            times.zip(found).forEach { (expected, actual) -> assertEquals(expected,actual,.1) }
        }
    }
}
