package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.nio.file.AccessDeniedException
import java.nio.file.DirectoryIteratorException
import java.nio.file.NoSuchFileException

class StorageDocumentTreeTest {
    private fun id(value: String) = StorageDocumentPolicy.id(value)
    private fun uri(tree: String, doc: String = tree) = StorageDocumentPolicy.document(id(tree), id(doc))
    private class Provider : StorageDocumentTree.Provider {
        val allowed = mutableListOf<String>()
        val rows = mutableMapOf<Pair<String, Boolean>, List<StorageDocumentTree.Entry>>()
        var denied = false
        override fun grants() = allowed.toList()
        override fun query(uri: String, children: Boolean): List<StorageDocumentTree.Entry> {
            if (denied) throw AccessDeniedException("fixture")
            return rows[uri to children] ?: throw NoSuchFileException("fixture")
        }
    }
    private fun rejected(action: () -> Unit) { try { action(); fail("Invalid identity accepted") } catch (_: IllegalArgumentException) { } }
    @Test fun utf8PlusAndPercentAreDecodedOnceAndPreserved() {
        val expected = "1234-ABCD:电影/片+名%20🎬.mkv"
        assertEquals(expected, StorageDocumentPolicy.parse(uri("1234-ABCD:", expected)).document.text)
        rejected { StorageDocumentPolicy.parse("content://other.provider/tree/1234-ABCD%3A") }
        rejected { StorageDocumentPolicy.parse("content://user@com.android.externalstorage.documents/tree/1234-ABCD%3A") }
        rejected { StorageDocumentPolicy.parse(uri("1234-ABCD:") + "?other=1") }
    }
    @Test fun grantDoesNotAuthorizeAnotherPartitionOrParentOrSiblingPrefix() {
        val provider = Provider(); provider.allowed.add(uri("1234-ABCD:Movies"))
        val tree = StorageDocumentTree(provider)
        assertTrue(tree.authorized(uri("1234-ABCD:Movies", "1234-ABCD:Movies/电影.mkv")))
        assertFalse(tree.authorized(uri("9876-DCBA:Movies")))
        assertFalse(tree.authorized(uri("1234-ABCD:")))
        rejected { uri("1234-ABCD:Movies", "1234-ABCD:Movies2/a.mkv") }
        rejected { uri("1234-ABCD:Movies", "1234-ABCD:Movies/../a.mkv") }
        rejected { uri("1234-ABCD:", "9876-DCBA:a.mkv") }
    }
    @Test fun bothMountedPartitionsBrowseWithIndependentReadOnlyGrants() {
        val provider = Provider()
        for (volume in listOf("1234-ABCD", "9876-DCBA")) {
            val root = "$volume:"
            provider.allowed.add(StorageDocumentPolicy.tree(id(root)))
            provider.rows[uri(root) to true] = listOf(
                StorageDocumentTree.Entry(root + "电影🎬.mkv", "电影🎬.mkv", false, 6_000_000_000L),
                StorageDocumentTree.Entry(root + "Movies", "Movies", true),
                StorageDocumentTree.Entry(root + "notes.txt", "notes.txt", false),
                StorageDocumentTree.Entry("other:outside.mp4", "outside.mp4", false))
        }
        val tree = StorageDocumentTree(provider)
        for (volume in listOf("1234-ABCD", "9876-DCBA")) {
            val rows = tree.root(volume)
            assertEquals(2, rows.length()); assertTrue(rows.getJSONObject(0).getBoolean("container"))
            val movie = rows.getJSONObject(1)
            assertEquals(6_000_000_000L, movie.getLong("size"))
            assertEquals(volume, StorageDocumentPolicy.parse(movie.getString("uri")).document.volume)
            assertFalse(movie.getBoolean("can_delete")); assertFalse(movie.getBoolean("can_rename")); assertTrue(movie.getBoolean("read_only"))
        }
        provider.allowed.removeAt(1)
        try { tree.root("9876-DCBA"); fail("Other partition grant reused") } catch (_: AccessDeniedException) { }
    }
    @Test fun selectedSubfolderIsShownExplicitlyAndNestedGrantsStillWork() {
        val provider = Provider(); provider.allowed.add(uri("1234-ABCD:Movies/中文"))
        provider.rows[uri("1234-ABCD:Movies/中文") to false] = listOf(StorageDocumentTree.Entry("1234-ABCD:Movies/中文", "中文", true))
        val tree = StorageDocumentTree(provider)
        assertEquals("中文", tree.root("1234-ABCD").getJSONObject(0).getString("title"))
        provider.allowed.add(uri("1234-ABCD:"))
        assertTrue(tree.authorized(uri("1234-ABCD:Movies/中文")))
        assertEquals(listOf(id("1234-ABCD:")), tree.grants("1234-ABCD"))
    }
    @Test fun revokedGrantAndMissingFolderAreNotSuccessfulEmptyDirectories() {
        val provider = Provider(); provider.allowed.add(uri("1234-ABCD:")); val tree = StorageDocumentTree(provider)
        try { tree.root("1234-ABCD"); fail("Missing reported as empty") } catch (_: NoSuchFileException) { }
        provider.denied = true
        try { tree.root("1234-ABCD"); fail("Denied reported as empty") } catch (_: AccessDeniedException) { }
    }
    @Test fun subtitlesAndRelativeStrmStayWithinTheGrantedTree() {
        val root = "1234-ABCD:Movies"
        val movie = uri(root, "$root/sub/电影.strm")
        assertEquals(uri(root, "$root/片.mkv"), StorageDocumentPolicy.relative(movie, "../片.mkv"))
        assertEquals(uri(root, "$root/sub"), StorageDocumentPolicy.parent(movie))
        assertNull(StorageDocumentPolicy.parent(uri(root)))
        rejected { StorageDocumentPolicy.relative(movie, "../../outside.mkv") }
        assertEquals(uri(root, "$root/sub/片.mkv"), StrmFile.target(movie, "片.mkv"))
    }
    @Test fun ioAndMissingFailuresNeverSendUsersToAllFilesSettings() {
        assertEquals("STORAGE_FOLDER_ACCESS_NEEDED", LocalStorageReadPolicy.failure(AccessDeniedException("test"), true, false).message)
        assertEquals("ALL_FILES_ACCESS_NEEDED", LocalStorageReadPolicy.failure(AccessDeniedException("test"), false, false).message)
        for (error in listOf(IOException("I/O"), NoSuchFileException("missing"))) {
            for (removable in listOf(false, true)) assertEquals("error", LocalStorageReadPolicy.failure(error, removable, false).state)
        }
        assertEquals("error", LocalStorageReadPolicy.failure(SecurityException(), false, true).state)
        assertEquals("STORAGE_FOLDER_ACCESS_NEEDED", LocalStorageReadPolicy.failure(DirectoryIteratorException(AccessDeniedException("fixture")), true, false).message)
    }
}
