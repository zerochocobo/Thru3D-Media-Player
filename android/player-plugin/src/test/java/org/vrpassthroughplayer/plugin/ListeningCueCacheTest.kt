package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class ListeningCueCacheTest {
    private val manifest = JSONObject("""{"revision":"r1","models":{"ja":{"files":{"a.ort":{"sha256":"aa"}}},"en":{"files":{"a.ort":{"sha256":"bb"}}}}}""")
    private fun cue(start: Double, end: Double, text: String) = ListeningPolicy.Cue(start, end, text)

    @Test fun coveredTimeResumesAtItsEndAndReturnsItsCues() {
        val cache = ListeningCueCache.load(null, "k", true)
        cache.add(cue(201.0, 203.0, "a")); cache.add(cue(250.0, 252.0, "b"))
        cache.cover(200.0, 240.0); cache.cover(238.0, 300.0); cache.cover(400.0, 420.0)
        assertEquals(300.0, cache.coveredEnd(210.0)!!, 0.0)
        assertEquals(300.0, cache.coveredEnd(199.8)!!, 0.0) // the anchor sits 0.25 s before the clock
        assertNull(cache.coveredEnd(350.0))
        assertEquals(listOf("b"), cache.cues(249.0, 300.0).map { it.text })
        cache.add(cue(201.0, 203.0, "a")) // a repeated finished line is stored once
        assertEquals(2, cache.cues(0.0, 1000.0).size)
    }

    @Test fun storedEntryReloadsOnlyForTheSameVideoLanguageAndModel() {
        val dir = Files.createTempDirectory("cues").toFile()
        try {
            val model = ListeningCueCache.modelIdentity(manifest, "ja")
            val key = ListeningCueCache.key("ab".repeat(32), 5400.0, "ja", model)
            val cache = ListeningCueCache.load(dir, key, true)
            cache.add(cue(10.0, 12.0, "こんにちは")); cache.cover(9.0, 30.0)
            cache.write(cache.snapshot(true)!!)
            assertNull("Nothing new to write", cache.snapshot(true))
            val again = ListeningCueCache.load(dir, key, true)
            assertEquals(30.0, again.coveredEnd(9.5)!!, 0.0)
            assertEquals("こんにちは", again.cues(0.0, 40.0).single().text)
            // A model upgrade, another language or another file never reuses it.
            val upgraded = JSONObject(manifest.toString()).put("revision", "r2")
            assertNotEquals(key, ListeningCueCache.key("ab".repeat(32), 5400.0, "ja", ListeningCueCache.modelIdentity(upgraded, "ja")))
            assertNotEquals(key, ListeningCueCache.key("ab".repeat(32), 5400.0, "en", ListeningCueCache.modelIdentity(manifest, "en")))
            assertNotEquals(key, ListeningCueCache.key("ab".repeat(32), 5401.0, "ja", model))
            assertTrue(ListeningCueCache.load(dir, "other", true).cues(0.0, 40.0).isEmpty())
        } finally { dir.deleteRecursively() }
    }

    @Test fun memoryOnlyEntriesNeverTouchDiskAndCleanupHonoursNetworkOnly() {
        val files = Files.createTempDirectory("files").toFile()
        try {
            val memory = ListeningCueCache.load(null, "m", true)
            memory.add(cue(1.0, 2.0, "x")); memory.cover(0.0, 5.0)
            assertNull(memory.snapshot(true))
            val dir = ListeningCueCache.directory(files)
            for ((key, network) in listOf("net" to true, "local" to false)) {
                val cache = ListeningCueCache.load(dir, key, network); cache.cover(0.0, 5.0); cache.write(cache.snapshot(true)!!)
            }
            assertTrue(ListeningCueCache.clear(files, networkOnly = true))
            assertEquals(listOf("local.json"), dir.list()!!.toList())
            assertTrue(ListeningCueCache.clear(files, networkOnly = false))
            assertTrue(dir.list()!!.isEmpty())
        } finally { files.deleteRecursively() }
    }

    @Test fun configCarriesTheMediaKeyAndPersistsOnlyWithOne() {
        val media = "ab".repeat(32)
        val config = ListeningPolicy.Config.parse("""{"enabled":true,"language":"ja","lead":12,"target":"","media":"$media","persist":true,"network":true}""")
        assertEquals(media, config.media); assertTrue(config.persist)
        assertFalse(ListeningPolicy.Config.parse("""{"enabled":true,"language":"ja","lead":12,"persist":true}""").persist)
        assertThrows(IllegalArgumentException::class.java) {
            ListeningPolicy.Config.parse("""{"enabled":true,"language":"ja","lead":12,"media":"../x"}""")
        }
    }
}
