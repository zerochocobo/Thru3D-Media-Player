package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class OpenListPlaybackTest {
    private val mount = "/12345678-1234-1234-1234-123456789abc"

    @Test fun freshFindIsConsumedOnceAndExpiredOrListedMetadataIsVerified() {
        var calls = 0
        var time = 0L
        var id = "1"
        val client = OpenListBackend.Client(mount, CloudDrive.OPEN115,
            stream = { "http://127.0.0.1:1234/capability/movie.mp4" }, now = { time }) { _, route, _ ->
            assertEquals("/stat115", route)
            calls++
            JSONObject().put("stream", "http://127.0.0.1:1234/capability-115/lease/movie.mp4").put("data", JSONObject().put("name", "movie.mp4").put("is_dir", false).put("size", 100).put("id", id))
        }
        val found = client.find("/movie.mp4")
        client.resolve(found)
        assertEquals(1, calls) // Same open no longer searches the path twice.
        client.resolve(found)
        assertEquals(2, calls) // Re-resolving the stream verifies again.
        val expired = client.find("/movie.mp4")
        time = 10_000
        client.resolve(expired)
        assertEquals(4, calls)
        id = "2"
        assertThrows(CloudFailure::class.java) { client.resolve(found) }
        assertEquals(5, calls)
    }

    @Test fun aDifferentObjectCannotConsumeAnotherFilesFreshIdentity() {
        var calls = 0
        val client = OpenListBackend.Client(mount, CloudDrive.OPEN115,
            stream = { "http://127.0.0.1:1234/capability/movie.mp4" }) { _, route, _ ->
            assertEquals("/stat115", route); calls++
            JSONObject().put("stream", "http://127.0.0.1:1234/capability-115/lease/movie.mp4").put("data", JSONObject().put("name", "movie.mp4").put("is_dir", false).put("size", 100).put("id", "1"))
        }
        val found = client.find("/movie.mp4")
        client.resolve(CloudFile(found.name, false, found.size, found.id, objectId = "1"))
        assertEquals(2, calls)
    }

    @Test fun nativeCompanionsUseDedicatedSearchRatherThanFullDirectorySearchFallback() {
        val client = OpenListBackend.Client(mount, CloudDrive.OPEN115) { _, route, body ->
            assertEquals("/companions115", route)
            assertEquals("/Movies/movie.mp4", body!!.getString("path"))
            JSONObject().put("data", JSONObject().put("content", JSONArray().put(JSONObject()
                .put("name", "movie.zh.srt").put("id", "99").put("is_dir", false).put("size", 100))))
        }
        val file = client.companions("/Movies/movie.mp4", emptyList()).single()
        assertEquals("/Movies/movie.zh.srt", file.id)
        assertEquals("99", file.objectId)
    }
    @Test fun otherProvidersRecoverCaptionsBeyondTheFirstPageOnAHistoryOpen() {
        for (provider in listOf(CloudDrive.BAIDU, CloudDrive.ALIYUN, CloudDrive.QUARK, CloudDrive.ONEDRIVE, CloudDrive.WEBDAV)) {
            val offsets = ArrayList<Int>()
            val client = OpenListBackend.Client(mount, provider) { _, route, body ->
                assertEquals("/directory", route)
                assertEquals("/Movies", body!!.getString("path"))
                val offset = body.getInt("offset"); offsets.add(offset)
                val rows = JSONArray()
                if (offset == 0) repeat(48) { rows.put(JSONObject().put("name", if (it == 0) "movie.mp4" else "other-$it.bin").put("is_dir", false).put("size", 100)) }
                else rows.put(JSONObject().put("name", "movie.zh.srt").put("is_dir", false).put("size", 100))
                JSONObject().put("data", JSONObject().put("content", rows).put("total", 49).put("next_offset", if (offset == 0) 48 else -1))
            }
            val selected = CloudPlaybackPages.Playback("/Movies/movie.mp4", "mount", CloudPlaybackPages.Selection())
            val captions = SidecarSubtitles.forCloud(selected.path, selected.automatic(client)) { it.id }
            assertEquals(listOf("movie.zh.srt"), captions.map { it.title })
            selected.automatic(client)
            assertEquals(listOf(0, 48), offsets)
        }
    }
    @Test fun knownParentReachesPlaybackCompanionsAndManagementRequests() {
        val routes=ArrayList<String>()
        val client=OpenListBackend.Client(mount,CloudDrive.OPEN115,"42") { _,route,body ->
            routes.add(route)
            assertEquals("42",body!!.getString("folder_id"))
            val item=JSONObject().put("name","movie.mp4").put("id","9").put("is_dir",false).put("size",100)
                .put("can_delete",true).put("can_rename",true)
            JSONObject().put("stream", "http://127.0.0.1:1234/capability-115/lease/movie.mp4").put("data",if(route=="/stat115")item else JSONObject().put("content",JSONArray().put(item)))
        }
        val file=client.find("/MOVIE/V/sub/movie.mp4")
        client.companions(file.id,emptyList())
        client.freshMatches("/MOVIE/V/sub",listOf("movie","new"))
        client.remove(file.id,file)
        client.rename(file.id,file,"new.mp4")
        assertEquals(listOf("/stat115","/companions115","/matches115","/remove115","/rename115"),routes)
    }
    @Test fun selectedIdentityAndNativeLeaseBypassGenericPathStream() {
        var calls = 0
        val client = OpenListBackend.Client(mount, CloudDrive.OPEN115,
            stream = { error("115 playback must not use the generic path proxy") }) { _, route, body ->
            assertEquals("/stat115", route)
            assertEquals("9", body!!.getString("id"))
            calls++
            JSONObject().put("stream", "http://127.0.0.1:1234/capability-115/lease/movie.mp4")
                .put("data", JSONObject().put("name", "movie.mp4").put("id", "9").put("is_dir", false).put("size", 100))
        }
        val selected = CloudFile("movie.mp4", false, 99, "/movie.mp4", objectId = "9")
        val fresh = client.findForPlayback(selected.id, selected)
        assertEquals(100, fresh.size)
        assertTrue(client.resolve(fresh).url.contains("capability-115/lease"))
        assertEquals(1, calls)
        client.resolve(fresh)
        assertEquals(2, calls)
    }
}
