package org.vrpassthroughplayer.plugin

import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PanoramaOriginalsTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun store() = PanoramaOriginals { File(temporary.root, "online-panoramas") }
    private fun original(store: PanoramaOriginals, name: String): File =
        File(store.prepare(), name).apply { writeText(name); store.register(this) }

    @Test fun handedOffOriginalLivesUntilViewerCloses() {
        val store = store()
        val file = original(store, "sky.jpg")
        val metadata = File(file.path + ".json").apply { writeText("source") }
        store.view(file.toURI().toString())
        store.release(file) // Downloader hands ownership to viewer.
        assertTrue(file.exists())
        store.view("")
        assertFalse(file.exists())
        assertFalse(metadata.exists())
    }

    @Test fun switchingKeepsIncomingOriginalAndDeletesOutgoing() {
        val store = store()
        val first = original(store, "first.jpg")
        store.view(first.toURI().toString()); store.release(first)
        val second = original(store, "second.jpg")
        store.view(second.toURI().toString()); store.release(second)
        assertFalse(first.exists())
        assertTrue(second.exists())
        store.close()
        assertFalse(second.exists())
    }

    @Test fun publicSaveLeaseSurvivesClosingViewerAndPublicCopyIsNeverDeleted() {
        val store = store()
        val file = original(store, "sky.jpg")
        store.view(file.toURI().toString()); store.release(file)
        val saving = requireNotNull(store.retain(file.toURI().toString()))
        store.view("")
        assertTrue(file.exists())
        val public = File(temporary.root, "Pictures/Thru3D/sky.jpg")
        requireNotNull(public.parentFile).mkdirs(); saving.copyTo(public)
        store.release(saving)
        assertFalse(file.exists())
        assertEquals("sky.jpg", public.readText())
        store().prepare() // A subsequent app launch also leaves Pictures alone.
        assertTrue(public.exists())
    }

    @Test fun cancelledUnclaimedDownloadIsRemoved() {
        val store = store()
        val file = original(store, "ready.jpg")
        store.release(file)
        assertFalse(file.exists())
        assertNull(store.retain(file.toURI().toString()))
    }

    @Test fun startupRemovesLegacyOriginalsMetadataAndInterruptedDownloadsOnlyInDedicatedFolder() {
        val root = File(temporary.root, "online-panoramas").apply { mkdirs() }
        for (name in listOf("old.jpg", "old.jpg.json", "interrupted.part")) File(root, name).writeText(name)
        val sibling = File(temporary.root, "personal.jpg").apply { writeText("keep") }
        val nested = File(root, "other/keep.jpg").apply { requireNotNull(parentFile).mkdirs(); writeText("keep") }
        store().prepare()
        assertTrue(root.listFiles()!!.none { it.isFile })
        assertTrue(sibling.exists()); assertTrue(nested.exists())
    }

    @Test fun repeatedPrepareAndSameImageReopenDoNotSweepActiveFiles() {
        val store = store()
        val file = original(store, "same.jpg")
        store.view(file.toURI().toString()); store.release(file)
        store.prepare(); store.view(file.toURI().toString())
        assertTrue(file.exists())
        store.close()
        assertFalse(file.exists())
    }

    @Test fun outsideFilesCannotBeClaimedOrDeleted() {
        val store = store()
        val outside = File(temporary.root, "personal.jpg").apply { writeText("keep") }
        assertNull(store.retain(outside.toURI().toString()))
        assertNull(store.retain("content://media/1"))
        store.release(outside); store.view(outside.toURI().toString()); store.close()
        assertEquals("keep", outside.readText())
    }
}
