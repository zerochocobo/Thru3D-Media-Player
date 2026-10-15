package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CloudRenameTest {
    @Test fun openListDtoSeparatesRenamePermissionAndDispatchesTheVerifiedId() {
        val calls = ArrayList<Pair<String, JSONObject>>()
        val client = OpenListBackend.Client("/11111111-1111-4111-8111-111111111111", CloudDrive.OPEN115) { _, route, body ->
            calls.add(route to body!!)
            val data = if (route == "/list115") JSONObject().put("total", 1).put("content", org.json.JSONArray().put(
                JSONObject().put("name", "old.folder").put("is_dir", true).put("id", "9007199254740993")
                    .put("size", 0).put("modified_ms", 10).put("can_delete", false).put("can_rename", true))) else JSONObject()
            JSONObject().put("code", 200).put("data", data)
        }
        val item = client.page("/", 0, true).files.single()
        assertTrue(item.canRename); assertFalse(item.canDelete)
        client.rename(item.id, item, "new.folder")
        assertEquals("/rename115", calls.last().first)
        assertEquals("9007199254740993", calls.last().second.getString("id"))
        assertTrue(calls.last().second.getBoolean("folder"))
        assertEquals("new.folder", calls.last().second.getString("new_name"))
    }
    private fun file(name: String, id: String, folder: Boolean = false, writable: Boolean = true) =
        CloudFile(name, folder, 12, "/$name", modified = 10, objectId = id, canRename = writable)
    private fun request(item: CloudFile, stem: String = "new", same: Boolean = true) = JSONObject()
        .put("cloud_id", item.objectId).put("folder", item.folder).put("size", item.size).put("modified", item.modified)
        .put("new_name", stem).put("include_same_name", same)
    private class Fake : CloudClient {
        override val canRename = true
        val files = mutableListOf<CloudFile>()
        val reads = mutableListOf<String>()
        var writes = 0
        var loseResponse = false
        var failReadBack = false
        override fun page(path: String, offset: Int, refresh: Boolean): CloudPage {
            reads.add(path)
            if (writes > 0 && failReadBack) throw CloudFailure()
            check(path == "/") { "Folder rename must not scan descendants" }
            val end = minOf(offset + 48, files.size)
            return CloudPage(files.subList(offset, end).toList(), if (end < files.size) end else -1, files.size)
        }
        override fun rename(path: String, file: CloudFile, newName: String) {
            assertEquals(file.id, path)
            writes++
            val index = files.indexOfFirst { it.objectId == file.objectId }
            files[index] = CloudFile(newName, file.folder, file.size, "/$newName", modified = file.modified,
                objectId = file.objectId, canRename = file.canRename)
            if (loseResponse) throw CloudFailure()
        }
        override fun list(path: String): List<CloudFile> = error("Must use fresh pages")
        override fun find(path: String): CloudFile = error("Must not trust playback caches")
        override fun resolve(file: CloudFile): CloudLink = error("Must not download")
    }
    private fun prepare(client: Fake, item: CloudFile, stem: String = "new", same: Boolean = true): JSONObject {
        val request = request(item, stem, same)
        request.put("plan", CloudRename(client).run(item.id, request, true).getString("plan"))
        assertEquals(0, client.writes)
        return request
    }
    @Test fun anyExtensionCompanionsAreOptionalAndNoPrefixOrFolderIsIncluded() {
        val item = file("old.mp4", "1")
        val client = Fake().apply { files.addAll(listOf(item, file("old.nfo", "2"), file("old.JPG", "3"),
            file("old.zh.srt", "4"), file("old2.srt", "5"), file("old.flac", "6", true))) }
        val req = prepare(client, item)
        val result = CloudRename(client).run(item.id, req, false)
        assertTrue(result.getBoolean("renamed")); assertEquals(3, client.writes)
        assertEquals(setOf("new.mp4", "new.nfo", "new.JPG", "old.zh.srt", "old2.srt", "old.flac"), client.files.map { it.name }.toSet())
        val second = client.files.first { it.objectId == "1" }
        client.writes = 0
        val single = prepare(client, second, "single", false)
        assertTrue(CloudRename(client).run(second.id, single, false).getBoolean("renamed"))
        assertEquals(1, client.writes); assertTrue(client.files.any { it.name == "new.nfo" })
    }
    @Test fun folderWithDotsRenamesAsOneObjectWithoutScanningChildrenAndWithoutDeletePermission() {
        val item = file("old.folder", "9007199254740993", true)
        val client = Fake().apply { files.add(item) }
        val req = prepare(client, item, "new.folder")
        val result = CloudRename(client).run(item.id, req, false)
        assertTrue(result.getBoolean("renamed")); assertEquals("/new.folder", result.getString("new_path"))
        assertEquals(1, client.writes); assertTrue(client.reads.all { it == "/" })
    }
    @Test fun replacedObjectsChangedMetadataAndDestinationFolderBlockWrites() {
        val item = file("old.mp4", "1")
        for (replacement in listOf(file("old.mp4", "2"), file("old.mp4", "1", writable = false))) {
            val client = Fake().apply { files.add(replacement) }
            assertThrows(IllegalStateException::class.java) { CloudRename(client).run(item.id, request(item), true) }
            assertEquals(0, client.writes)
        }
        val client = Fake().apply { files.addAll(listOf(item, file("new.mp4", "2", true))) }
        assertThrows(IllegalStateException::class.java) { CloudRename(client).run(item.id, request(item), true) }
        assertEquals(0, client.writes)
    }
    @Test fun confirmedPlanCannotChangeCompanionOptionOrIncludeChangedCompanions() {
        val item = file("old.mp4", "1")
        val client = Fake().apply { files.addAll(listOf(item, file("old.srt", "2"))) }
        val req = prepare(client, item)
        req.put("include_same_name", false)
        assertThrows(IllegalStateException::class.java) { CloudRename(client).run(item.id, req, false) }
        req.put("include_same_name", true)
        client.files[1] = file("old.srt", "3")
        assertThrows(IllegalStateException::class.java) { CloudRename(client).run(item.id, req, false) }
        assertEquals(0, client.writes)
    }
    @Test fun lostResponseIsReadBackAndNeverReplayed() {
        val item = file("old.mp4", "1")
        val client = Fake().apply { files.add(item); loseResponse = true }
        val req = prepare(client, item)
        assertTrue(CloudRename(client).run(item.id, req, false).getBoolean("renamed"))
        assertEquals(1, client.writes)
    }
    @Test fun uncertainWriteReportsUnknownMovesAndDoesNotRetry() {
        val item = file("old.mp4", "1")
        val client = Fake().apply { files.add(item) }
        val req = prepare(client, item)
        client.failReadBack = true
        val result = CloudRename(client).run(item.id, req, false)
        assertFalse(result.getBoolean("renamed")); assertEquals(1, result.getJSONArray("unknown_moves").length())
        assertEquals(1, client.writes)
    }
    @Test fun selectingOneDuplicateNameUsesOnlyItsVerifiedId() {
        val item = file("old.mp4", "1")
        val client = Fake().apply { files.addAll(listOf(item, file("old.mp4", "2"))) }
        val req = prepare(client, item, same = false)
        assertTrue(CloudRename(client).run(item.id, req, false).getBoolean("renamed"))
        assertEquals("old.mp4", client.files.single { it.objectId == "2" }.name); assertEquals(1, client.writes)
    }
}
