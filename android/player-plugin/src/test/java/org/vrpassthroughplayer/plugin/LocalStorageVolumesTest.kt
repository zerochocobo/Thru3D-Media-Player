package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class LocalStorageVolumesTest {
    @Test fun mountedVolumeWithoutPublicPathRetainsAnUnprivilegedDocumentEntry() {
        val access = LocalStorageVolumePolicy.access("mounted", null, "1234-ABCD", true)!!
        assertTrue(access.documentOnly)
        val at = StorageDocumentPolicy.parse(access.location)
        assertEquals("1234-ABCD", at.tree.volume)
        assertEquals("", at.tree.path)
        assertEquals(at.tree, at.document)
        assertNotNull(LocalStorageVolumePolicy.access("mounted_ro", null, "1234-ABCD", true))
    }
    @Test fun missingPathNeverMakesAnUnmountedOrUnidentifiedVolumeAccessible() {
        for (state in listOf("unmounted", "removed", "checking", "unmountable", "ejecting"))
            assertNull(LocalStorageVolumePolicy.access(state, null, "1234-ABCD", true))
        for (uuid in listOf(null, "", "../../emulated/0", "1234:Movies", "1234/ABCD", "a".repeat(65)))
            assertNull(LocalStorageVolumePolicy.access("mounted", null, uuid, true))
        assertNull(LocalStorageVolumePolicy.access("mounted", null, "primary", false))
    }
    @Test fun usablePublicPathsRetainTheirIdentityAndFileAccess() {
        val external = LocalStorageVolumePolicy.access("mounted", "/storage/1234-ABCD", "1234-ABCD", true)!!
        assertEquals("/storage/1234-ABCD", external.location)
        assertFalse(external.documentOnly)
        val internal = LocalStorageVolumePolicy.access("mounted", "/storage/emulated/0", null, false)!!
        assertEquals("/storage/emulated/0", internal.location)
        assertFalse(internal.documentOnly)
    }
    @Test fun privateAndUnreadableRemovablePathsUseDocumentsEvenWhenNonNull() {
        for (path in listOf("/mnt/media_rw/1234-ABCD", "/storage2/1234-ABCD", "/storage/../mnt/media_rw/1234-ABCD")) {
            val access = LocalStorageVolumePolicy.access("mounted", path, "1234-ABCD", true, true)!!
            assertTrue(access.documentOnly)
            assertEquals("1234-ABCD", StorageDocumentPolicy.parse(access.location).document.volume)
        }
        assertTrue(LocalStorageVolumePolicy.access("mounted_ro", "/storage/1234-ABCD", "1234-ABCD", true, false)!!.documentOnly)
        assertNull(LocalStorageVolumePolicy.access("mounted", "/mnt/media_rw/unknown", null, true, false))
        val internal = LocalStorageVolumePolicy.access("mounted", "/storage/emulated/0", null, false, false)!!
        assertEquals("/storage/emulated/0", internal.location)
        assertFalse(internal.documentOnly)
    }
    @Test fun unreadablePublicPathFallbackIsNotPinnedWhenAccessReturns() {
        val discovery = LocalStorageVolumePolicy.Discovery()
        val fallback = discovery.select("mounted", "/storage/1234-ABCD", "1234-ABCD", true, false)!!
        assertTrue(fallback.documentOnly)
        val restored = discovery.select("mounted", "/storage/1234-ABCD", "1234-ABCD", true, true)!!
        assertFalse(restored.documentOnly)
        assertEquals("/storage/1234-ABCD", restored.location)
        assertNull(discovery.select("checking", "/storage/1234-ABCD", "1234-ABCD", true, true))
    }
    @Test fun publicEntrySurvivesFirstGrantAndRestartWithoutAPreGrantProbe() {
        var probes = 0
        val path = "/storage/1234-ABCD"
        val discovery = LocalStorageVolumePolicy.Discovery()
        val beforeRead = LocalStorageVolumePolicy.probeDirectoryReadability(path, true, false) { probes++; false }
        assertNull(beforeRead)
        val before = discovery.select("mounted", path, "1234-ABCD", true, beforeRead)!!
        assertEquals(path, before.location)
        assertFalse(before.documentOnly)
        assertEquals(0, probes)
        val afterRead = LocalStorageVolumePolicy.probeDirectoryReadability(path, true, true) { probes++; true }
        assertEquals(true, afterRead)
        assertEquals(before, discovery.select("mounted", path, "1234-ABCD", true, afterRead))
        assertEquals(before, LocalStorageVolumePolicy.Discovery().select("mounted", path, "1234-ABCD", true, afterRead))
        assertEquals(1, probes)
    }
    @Test fun ungrantedInternalAndPrivatePathsDoNotPerformDirectoryIo() {
        fun unexpectedProbe(): Boolean = throw AssertionError("Unexpected filesystem probe")
        assertNull(LocalStorageVolumePolicy.probeDirectoryReadability("/storage/1234-ABCD", true, false, ::unexpectedProbe))
        assertNull(LocalStorageVolumePolicy.probeDirectoryReadability("/storage/emulated/0", false, true, ::unexpectedProbe))
        assertNull(LocalStorageVolumePolicy.probeDirectoryReadability("/mnt/media_rw/1234-ABCD", true, true, ::unexpectedProbe))
        assertNull(LocalStorageVolumePolicy.probeDirectoryReadability(null, true, true, ::unexpectedProbe))
    }
    @Test fun privatePathFallbackRemainsStableWhenAPublicPathAppears() {
        val discovery = LocalStorageVolumePolicy.Discovery()
        val privateEntry = discovery.select("mounted", "/mnt/media_rw/1234-ABCD", "1234-ABCD", true, null)!!
        assertTrue(privateEntry.documentOnly)
        assertEquals(privateEntry, discovery.select("mounted", "/storage/1234-ABCD", "1234-ABCD", true, true))
    }
    @Test fun documentEntriesNeverBecomeFileMutationRoots() {
        val document = LocalStorageVolumePolicy.access("mounted", null, "1234-ABCD", true)!!
        val roots = listOf(document.location to true, "/storage/emulated/0" to false, "/storage/9876-DCBA" to true)
        assertFalse(LocalStorageVolumePolicy.readOnlyPath("/storage/emulated/0/Movies/a.mp4", roots))
        assertTrue(LocalStorageVolumePolicy.readOnlyPath("/storage/9876-DCBA/Movies/a.mp4", roots))
    }
    @Test fun latePublicPathDoesNotReplaceAnActiveDocumentEntryOrResurrectAnUnmountedDisk() {
        val discovery = LocalStorageVolumePolicy.Discovery()
        val initial = discovery.select("mounted", null, "1234-ABCD", true)!!
        assertEquals(initial, discovery.select("mounted", "/storage/1234-ABCD", "1234-abcd", true))
        assertNull(discovery.select("unmounted", "/storage/1234-ABCD", "1234-ABCD", true))
        assertNull(discovery.select("removed", null, "1234-ABCD", true))
        val other = discovery.select("mounted", "/storage/9876-DCBA", "9876-DCBA", true)!!
        assertEquals("/storage/9876-DCBA", other.location)
        assertFalse(other.documentOnly)
    }

    @Test fun removableDirectoriesRemainReadOnlyWithGlobalManagementEnabled() {
        val roots = listOf("/storage/emulated/0" to false, "/storage/1234-5678" to true)
        assertTrue(LocalStorageVolumePolicy.readOnlyPath("/storage/1234-5678/Movies/a.mkv", roots))
        assertTrue(LocalStorageVolumePolicy.readOnlyPath("/storage/1234-5678", roots))
        assertFalse(LocalStorageVolumePolicy.readOnlyPath("/storage/1234-56780/a.mkv", roots))
        assertFalse(LocalStorageVolumePolicy.readOnlyPath("/storage/1234-5678/../emulated/0/a.mkv", roots))
    }
    @Test fun onlyMountedAndReadOnlyMountedVolumesAreAccessible() {
        assertTrue(LocalStorageVolumePolicy.mounted("mounted"))
        assertTrue(LocalStorageVolumePolicy.mounted("mounted_ro"))
        for (state in listOf("unmounted","removed","bad_removal","checking","ejecting","unmountable"))
            assertFalse(LocalStorageVolumePolicy.mounted(state))
    }
    @Test fun internalAndEmulatedStorageCannotBeEjected() {
        assertTrue(LocalStorageVolumePolicy.removable(true,false,false))
        assertFalse(LocalStorageVolumePolicy.removable(true,true,false))
        assertFalse(LocalStorageVolumePolicy.removable(true,false,true))
        assertFalse(LocalStorageVolumePolicy.removable(false,false,false))
    }
    @Test fun android10CandidatesIncludePublicUuidAndAppStorageRootsWithoutDuplicates() {
        assertEquals(listOf("/storage/1234-5678","/mnt/external_usb"),
            LocalStorageVolumePolicy.legacyCandidates("1234-5678",listOf(
                "/storage/1234-5678/Android/data/com.wapok.thru3d/files",
                "/mnt/external_usb/Android/data/com.wapok.thru3d/files")))
        assertTrue(LocalStorageVolumePolicy.legacyCandidates("../../emulated/0",emptyList()).isEmpty())
        assertTrue(LocalStorageVolumePolicy.legacyCandidates(null,listOf("/not/an/app/root")).isEmpty())
    }
}
