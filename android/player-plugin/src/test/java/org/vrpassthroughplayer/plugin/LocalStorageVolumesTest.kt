package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class LocalStorageVolumesTest {
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
