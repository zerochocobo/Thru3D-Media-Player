package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.io.File

class ListeningCueCacheTest {
    private val manifest = JSONObject("""{"revision":"r1","models":{"ja":{"files":{"a.ort":{"sha256":"aa"}}},"en":{"files":{"a.ort":{"sha256":"bb"}}}}}""")
    private fun cue(start: Double, end: Double, text: String) = ListeningPolicy.Cue(start, end, text)

    @Test fun coveredTimeResumesAtItsEndAndReturnsItsCues() {
        val cache = ListeningCueCache.load(null, "k", true)
        cache.add(cue(201.0, 203.0, "a")); cache.add(cue(250.0, 252.0, "b"))
        cache.cover(200.0, 240.0); cache.cover(238.0, 300.0); cache.cover(400.0, 420.0)
        assertEquals(300.0, cache.coveredEnd(210.0)!!, 0.0)
        assertNull("A small unprocessed gap is still a gap", cache.coveredEnd(199.8))
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

    @Test fun fullFilmRequiresEveryIntervalAndARealDrainedEnd() {
        val cache=ListeningCueCache.load(null,"film",false)
        cache.cover(0.0,30.0);cache.cover(31.0,100.0)
        cache.finish(100.0,100.0)
        assertFalse(cache.complete(100.0))
        assertEquals(30.0,cache.firstGap(100.0),0.0)
        assertEquals(99.0,cache.coveredSeconds(100.0),0.0)
        cache.cover(30.0,31.0)
        assertTrue("Silence needs no subtitle rows to be fully analyzed",cache.complete(100.0))
        val noEnd=ListeningCueCache.load(null,"noEnd",false);noEnd.cover(0.0,100.0)
        assertFalse(noEnd.complete(100.0))
    }

    @Test fun translationsReuseOriginalsAcrossTargetsAndPersistAtomically() {
        val dir=Files.createTempDirectory("translated-cues").toFile()
        try {
            val cache=ListeningCueCache.obtain(dir,"film",false)
            cache.add(cue(0.0,2.0,"original"));cache.cover(0.0,10.0);cache.finish(10.0,10.0)
            assertFalse("Not saved yet",cache.complete(10.0))
            assertTrue(cache.flush(true));assertTrue(cache.complete(10.0))
            assertTrue(cache.translate("original","zh-Hans","译文"))
            assertEquals(1,cache.translated("zh-Hans"));assertEquals(0,cache.translated("en"))
            assertFalse(cache.translate("unrecognized","zh-Hans","wrong"))
            assertFalse(cache.translationsSaved());assertTrue(cache.flush(true))
            val restored=ListeningCueCache.load(dir,"film",false)
            assertTrue(restored.complete(10.0));assertEquals("译文",restored.translation("original","zh-Hans"))
            assertEquals("original",restored.cues(0.0,10.0).single().text)
            assertSame(cache,ListeningCueCache.obtain(dir,"film",false))
        }finally{dir.deleteRecursively()}
    }

    @Test fun trackAndPlaylistNeverShareResultsAndClearRejectsLateWriters() {
        assertNotEquals(ListeningCueCache.key("m",10.0,"ja","model",1,1),ListeningCueCache.key("m",10.0,"ja","model",2,1))
        assertNotEquals(ListeningCueCache.key("m",10.0,"ja","model",1,1),ListeningCueCache.key("m",10.0,"ja","model",1,2))
        val files=Files.createTempDirectory("late-cues").toFile()
        try {
            val cache=ListeningCueCache.obtain(ListeningCueCache.directory(files),"film",false)
            cache.cover(0.0,10.0);val pending=cache.snapshot(true)!!
            assertTrue(ListeningCueCache.clear(files,false));assertFalse(cache.write(pending))
            cache.add(cue(0.0,1.0,"late"));assertEquals(0,cache.count())
            assertFalse(File(ListeningCueCache.directory(files),"film.json").exists())
        }finally{files.deleteRecursively()}
    }
    @Test fun truncatedInputCannotCertifyTheUnseenTailButKnownShortAudioCan() {
        val broken=ListeningCueCache.load(null,"broken",false)
        broken.cover(0.0,20.0);broken.finish(20.0,100.0)
        assertFalse(broken.complete(100.0));assertEquals("source_incomplete",broken.error)
        val short=ListeningCueCache.load(null,"short",false)
        short.cover(0.0,20.0);short.finish(20.0,100.0,20.0)
        assertTrue(short.complete(100.0))
    }
    @Test fun translationWorkPagesPastTheLiveCaptionLimitAndResumesWithoutRepeats() {
        val cache=ListeningCueCache.load(null,"many",false)
        repeat(180){cache.add(cue(it*2.0,it*2.0+1,"line $it"))}
        var translated=0
        while(cache.pending("zh-Hans").isNotEmpty()){
            val page=cache.pending("zh-Hans");assertTrue(page.size<=32)
            page.forEach{assertTrue(cache.translate(it.text,"zh-Hans","译文 $translated"));translated++}
        }
        assertEquals(180,translated);assertEquals(180,cache.translated("zh-Hans"))
        assertEquals(32,cache.pending("en").size)
    }
}
