package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLDecoder
import java.util.concurrent.CopyOnWriteArrayList
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class EmbyFolderBrowseTest {
    @Test fun photoLibrariesAndMixedFoldersPreservePhotosAndAlbums() {
        val photo = JSONObject().put("Id", "p1").put("Name", "No extension").put("Type", "Photo")
            .put("MediaType", "Photo").put("Width", 1365).put("Height", 2048).put("Path", "/private/picture_SBS.jpg")
        val album = folder(1, "PhotoAlbum")
        val libraries = listOf("homevideos", "photos", "", "movies", "music").mapIndexed { index, type ->
            folder(index + 10, "CollectionFolder").put("CollectionType", type)
        }
        for (provider in listOf("emby", "jellyfin")) {
            val queries = CopyOnWriteArrayList<Map<String, String>>()
            MediaServerClientTest.Fixture { request, _, _ ->
                val args = query(request); queries.add(args)
                if (URI(request.split(' ')[1]).path.endsWith("/Views")) reply(libraries, emptyMap())
                else reply(listOf(album, photo), args)
            }.use { fixture ->
                val account = MediaServerAccount("test", "Test", fixture.url, "fake", provider, "user1")
                MediaServerHttp(account).use { http ->
                    val client = EmbyClient(account, http)
                    val home = client.home(JSONObject())
                    assertEquals(4, home.getJSONArray("libraries").length())
                    assertTrue(home.getJSONObject("capabilities").getBoolean("photos"))
                    for (type in listOf("homevideos", "photos", "", "mixed")) {
                        val result = client.browse(JSONObject().put("mode", "library").put("collection_type", type).put("library_id", "library"))
                        assertEquals(2, result.getInt("total"))
                        assertEquals("false", queries.last()["Recursive"])
                        val nodes = result.getJSONArray("entries")
                        assertTrue(nodes.getJSONObject(0).getBoolean("container"))
                        val image = nodes.getJSONObject(1)
                        assertEquals("image", image.getString("kind"))
                        assertEquals("medialib://test/photo/p1", image.getString("uri"))
                        assertEquals(1365, image.getInt("width")); assertEquals(2048, image.getInt("height"))
                        assertEquals("picture_SBS.jpg", image.getString("basename"))
                        assertFalse(image.toString().contains("/private/"))
                    }
                    assertEquals(1, client.browse(JSONObject().put("mode", "photos")).getInt("total"))
                    assertEquals("Photo", queries.last()["IncludeItemTypes"])
                    assertEquals(0, client.browse(JSONObject().put("mode", "library").put("collection_type", "movies")).getInt("total"))
                }
            }
        }
    }

    @Test fun originalPhotoProxyPreservesBytesAndIndependentLifetimes() {
        val bytes = ByteArray(4096) { (it % 251).toByte() }
        val requests = CopyOnWriteArrayList<String>()
        for (provider in listOf("emby", "jellyfin")) {
            MediaServerClientTest.Fixture { request, headers, _ ->
                val path = URI(request.split(' ')[1]).path; requests.add(path)
                if (path.endsWith("/Items/p1")) MediaServerClientTest.Reply(body =
                    """{"Id":"p1","Name":"Photo","Type":"Photo","MediaType":"Photo","Path":"/private/image.heic"}""".toByteArray())
                else if (path.endsWith("/Items/p1/File")) {
                    val range = headers.getValue("range").removePrefix("bytes=").split('-')
                    val start = range[0].toInt(); val end = range[1].toIntOrNull() ?: bytes.lastIndex
                    MediaServerClientTest.Reply(206, "Content-Type: image/heic\r\nContent-Range: bytes $start-$end/${bytes.size}\r\n", bytes.copyOfRange(start, end + 1))
                } else MediaServerClientTest.Reply(404, body = byteArrayOf())
            }.use { fixture -> LocalStreamServer().use { local ->
                var account = MediaServerAccount("test", "Test", fixture.url, "fake", provider, "user1")
                val library = MediaServerLibrary({ null }, { local }, { 1 }, getAccount = { account }, emit = { _, _ -> })
                try {
                    val identity = MediaLibraryUri.photo("test", "p1")
                    assertEquals("test" to "p1", MediaLibraryUri.photoIdentity(identity))
                    for (bad in listOf("$identity?api_key=secret", "$identity/../p2", "medialib://user:pw@test/photo/p1"))
                        assertThrows(MediaServerFailure::class.java) { MediaLibraryUri.photoIdentity(bad) }
                    val first = library.playable(identity); val preview = library.playable(identity)
                    assertNotEquals(first, preview)
                    assertArrayEquals(bytes, URI(first).toURL().readBytes())
                    assertArrayEquals(bytes, URI(preview).toURL().readBytes())
                    library.release(preview)
                    assertArrayEquals(bytes, URI(first).toURL().readBytes())
                    assertTrue(library.sidecarAudio(identity).isEmpty())
                    assertFalse(requests.any { it.contains("PlaybackInfo") || it.contains("Images") || it.contains("Videos") })
                    MediaServerLibrary.invalidate(account.id)
                    val revoked = URI(first).toURL().openConnection() as java.net.HttpURLConnection
                    try { assertEquals(404, revoked.responseCode) } finally { revoked.disconnect() }
                } finally { library.close() }
            } }
        }
    }

    @Test fun optionalLivePhotoLibraryAndOriginal() {
        val base = System.getenv("VRPP_PHOTO_EMBY_URL").orEmpty()
        org.junit.Assume.assumeTrue(base.isNotBlank())
        val anonymous = MediaServerAccount("photo-live", "Test", base, "", "emby")
        val account = MediaServerHttp(anonymous).use { EmbyClient(anonymous, it).login(
            System.getenv("VRPP_PHOTO_EMBY_USER"), System.getenv("VRPP_PHOTO_EMBY_PASSWORD")) }
        MediaServerHttp(account).use { http ->
            val client = EmbyClient(account, http)
            val library = client.home(JSONObject()).getJSONArray("libraries").objects()
                .first { it.optString("collection_type") == "homevideos" }
            val root = client.browse(JSONObject().put("mode", "library").put("collection_type", "homevideos").put("library_id", library.getString("id")))
            assertTrue(root.getJSONArray("entries").length() > 0)
            val photos = client.browse(JSONObject().put("mode", "photos").put("library_id", library.getString("id")))
            val photo = photos.getJSONArray("entries").getJSONObject(0)
            assertEquals("image", photo.getString("kind"))
            val ids = mutableSetOf<String>(); var count = 0; var page = 1; var total: Int
            do {
                val result = client.browse(JSONObject().put("mode", "folders").put("parent_id", photo.getString("parent_id")).put("page", page++))
                total = result.getInt("total")
                val items = result.getJSONArray("entries").objects()
                assertTrue(items.isNotEmpty()); assertTrue(items.all { ids.add(it.getString("id")) })
                count += items.size
            } while (count < total)
            assertEquals(total, ids.size)
            HttpRangeStreamSource(account) { EmbyClient(account, it).photo(photo.getString("id")) }.use { source ->
                assertTrue(source.size > 0)
            }
            println("Live photo API: photos=${photos.getInt("total")}; album=$count; original Range verified")
        }
    }

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
        val unsupported = listOf("Audio", "AudioBook", "Book", "Game").map { type ->
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
