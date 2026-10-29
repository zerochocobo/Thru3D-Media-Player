package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLDecoder
import java.util.concurrent.CopyOnWriteArrayList
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class EmbyFolderBrowseTest {
    private fun query(request: String): Map<String, String> = URI(request.split(' ')[1]).rawQuery.orEmpty()
        .split('&').filter { it.contains('=') }.associate {
            val pair = it.split('=', limit = 2)
            URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair[1], "UTF-8")
        }

    private fun folder(id: Int, type: String = "Folder") = JSONObject()
        .put("Id", "folder$id").put("Name", "Folder $id").put("Type", type).put("IsFolder", true)
        .put("ChildCount", 0)

    // Apply the API's exact type filtering before counting/paging, unlike fixtures that
    // always return the same items regardless of IncludeItemTypes.
    private fun reply(items: List<JSONObject>, args: Map<String, String>): MediaServerClientTest.Reply {
        val include = args["IncludeItemTypes"]?.split(',')
        val exclude = args["ExcludeItemTypes"].orEmpty().split(',')
        val selected = items.filter { (include == null || it.optString("Type") in include) && it.optString("Type") !in exclude }
        return MediaServerClientTest.Reply(body = JSONObject()
            .put("Items", JSONArray(selected.drop(args["StartIndex"]?.toInt() ?: 0).take(args["Limit"]?.toInt() ?: 48)))
            .put("TotalRecordCount", selected.size).toString().toByteArray())
    }

    @Test fun folderTypesOutsideTheOldWhitelistRemainVisibleAndNavigable() {
        val folders = (1..48).map { folder(it, if (it <= 38) "Folder" else "UserView") }
        for (provider in listOf("emby", "jellyfin")) {
            val requests = CopyOnWriteArrayList<Map<String, String>>()
            MediaServerClientTest.Fixture { request, _, _ ->
                val args = query(request); requests.add(args)
                reply(if (args["ParentId"] == "library") folders else listOf(folder(49, "MusicAlbum")), args)
            }.use { fixture ->
                val account = MediaServerAccount("test", "Test", fixture.url, "fake", provider, "user1")
                MediaServerHttp(account).use { http ->
                    val client = EmbyClient(account, http)
                    val result = client.browse(JSONObject().put("mode", "folders").put("library_id", "library"))
                    assertEquals("$provider must count all 48 folders, not just the 38 known types", 48, result.getInt("total"))
                    val entries = result.getJSONArray("entries").objects()
                    assertEquals(folders.map { it.getString("Id") }, entries.map { it.getString("id") })
                    assertTrue(entries.all { it.getBoolean("container") && !it.has("uri") })
                    assertEquals("false", requests.last()["Recursive"])
                    assertEquals("library", requests.last()["ParentId"])

                    val child = client.browse(JSONObject().put("mode", "folders").put("library_id", "library")
                        .put("parent_id", entries.last().getString("id")))
                    assertEquals("folder48", requests.last()["ParentId"])
                    assertEquals("false", requests.last()["Recursive"])
                    assertEquals("folder49", child.getJSONArray("entries").getJSONObject(0).getString("id"))
                    assertTrue(child.getJSONArray("entries").getJSONObject(0).getBoolean("container"))
                }
            }
        }
    }

    @Test fun completeFolderPagingKeepsVideosAndExcludesUnsupportedLeafMedia() {
        val folders = (1..53).map { folder(it, if (it % 2 == 0) "UserView" else "Folder") }
        val videos = listOf("Movie", "Episode", "Video", "AdultVideo", "MusicVideo", "Trailer").map { type ->
            JSONObject().put("Id", type).put("Name", type).put("Type", type).put("MediaType", "Video").put("IsFolder", false)
        }
        val unsupported = listOf("Audio", "AudioBook", "Book", "Game", "Photo").map { type ->
            JSONObject().put("Id", type).put("Name", type).put("Type", type).put("IsFolder", false)
        }
        for (provider in listOf("emby", "jellyfin")) {
            val requests = CopyOnWriteArrayList<Map<String, String>>()
            MediaServerClientTest.Fixture { request, _, _ ->
                val args = query(request); requests.add(args); reply(folders + videos + unsupported, args)
            }.use { fixture ->
                val account = MediaServerAccount("test", "Test", fixture.url, "fake", provider, "user1")
                MediaServerHttp(account).use { http ->
                    val client = EmbyClient(account, http)
                    val request = JSONObject().put("mode", "folders").put("parent_id", "parent")
                        .put("sort", "title").put("direction", "ASC")
                    val first = client.browse(request)
                    val second = client.browse(request.put("page", 2))
                    val entries = (first.getJSONArray("entries").objects() + second.getJSONArray("entries").objects())
                    assertEquals(59, first.getInt("total")); assertEquals(59, second.getInt("total"))
                    assertEquals(48, first.getJSONArray("entries").length()); assertEquals(11, second.getJSONArray("entries").length())
                    assertEquals((folders + videos).map { it.getString("Id") }, entries.map { it.getString("id") })
                    assertTrue(entries.take(53).all { it.getBoolean("container") && !it.has("uri") })
                    assertTrue(entries.drop(53).all { !it.getBoolean("container") && it.getString("uri").startsWith("medialib://test/scene/") })
                    assertEquals(listOf("0", "48"), requests.map { it["StartIndex"] })
                    assertTrue(requests.all { it["ParentId"] == "parent" && it["Recursive"] == "false" &&
                        it["SortBy"] == "SortName" && it["SortOrder"] == "Ascending" })
                }
            }
        }
    }
}
