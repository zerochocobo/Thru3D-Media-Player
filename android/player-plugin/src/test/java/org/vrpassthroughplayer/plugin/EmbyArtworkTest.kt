package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLDecoder
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class EmbyArtworkTest {
    @Test fun detailBackgroundsPreferOwnThenInheritedThenLandscapeFallbacks() {
        val cases = listOf(
            Triple(""""BackdropImageTags":["a","b"],"ParentBackdropItemId":"series","ParentBackdropImageTags":["parent"]""", "[]", listOf("film/Backdrop/0", "film/Backdrop/1")),
            Triple(""""ParentBackdropItemId":"series","ParentBackdropImageTags":["","parent"]""", "[]", listOf("series/Backdrop/1")),
            Triple(""""ParentBackdropItemId":"series","ParentBackdropImageTags":[""],"ImageTags":{"Thumb":"t"}""", "[]", listOf("film/Thumb/0")),
            Triple(""""ImageTags":{"Primary":"poster"}""", """[{"ImageType":"Screenshot","ImageIndex":0,"Width":1280,"Height":720},{"ImageType":"Screenshot","ImageIndex":1,"Width":600,"Height":900}]""", listOf("film/Screenshot/0")),
            Triple(""""ImageTags":{"Primary":"poster"}""", "[]", emptyList())
        )
        for ((fields, images, expected) in cases) MediaServerClientTest.Fixture { request, _, _ ->
            MediaServerClientTest.Reply(body = (if (request.contains("/Images")) images else """{"Id":"film","Name":"Film","Type":"Movie",$fields}""").toByteArray())
        }.use { fixture ->
            val account = MediaServerAccount("test", "Test", fixture.url, "fake", "emby", "user1")
            MediaServerHttp(account).use { http ->
                val result = EmbyClient(account, http).detail("film").getJSONArray("backdrops").objects()
                assertEquals(expected, result.map { "${it.getString("id")}/${it.getString("image_type")}/${it.getInt("image_index")}" })
                if (expected == listOf("series/Backdrop/1")) assertEquals("parent", result.single().getString("image_tag"))
            }
        }
    }

    private fun query(request: String): Map<String, String> = URI("http://test" + request.split(' ')[1]).rawQuery.orEmpty()
        .split('&').filter { it.contains('=') }.associate { val pair = it.split('=', limit = 2)
            URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair[1], "UTF-8") }

    @Test fun singleMovieFolderLendsOnlyHorizontalArtworkWithoutChangingIdentityOrScanning() {
        val requests = mutableListOf<String>()
        MediaServerClientTest.Fixture { request, _, _ ->
            requests.add(request)
            MediaServerClientTest.Reply(body = """{"Items":[{"Id":"film","Type":"Movie","Name":"Full movie title",
                "Path":"/private/film.mp4","ImageTags":{"Thumb":"wide","Primary":"poster"},"BackdropImageTags":["back"]}],"TotalRecordCount":1}""".toByteArray())
        }.use { fixture ->
            val account = MediaServerAccount("test", "Test", fixture.url, "fake", "emby", "user1")
            MediaServerHttp(account).use { http ->
                val data = EmbyClient(account, http).folderArtwork("folder")
                assertEquals("folder", data.getString("scene_id")); assertFalse(data.has("uri"))
                val variants = data.getJSONObject("image_variants")
                assertEquals("film", variants.getJSONObject("Thumb").getString("id"))
                assertEquals("wide", variants.getJSONObject("Thumb").getString("image_tag"))
                assertTrue(variants.has("Backdrop")); assertFalse(variants.has("Primary")); assertFalse(data.toString().contains("/private"))
                assertEquals(1, requests.size)
                val args = query(requests.single())
                assertEquals("folder", args["ParentId"]); assertEquals("false", args["Recursive"]); assertEquals("2", args["Limit"])
                assertFalse(args.containsKey("IncludeItemTypes")); assertTrue(requests.single().contains("/Users/user1/Items"))
            }
        }
    }

    @Test fun ambiguousAndNonMovieFoldersNeverBorrowAnArbitraryCover() {
        val responses = listOf(
            """{"Items":[],"TotalRecordCount":0}""",
            """{"Items":[{"Id":"film","Type":"Movie","ImageTags":{"Thumb":"t"}}],"TotalRecordCount":2}""",
            """{"Items":[{"Id":"a","Type":"Movie"},{"Id":"b","Type":"Movie"}],"TotalRecordCount":2}""",
            """{"Items":[{"Id":"sub","Type":"Folder","IsFolder":true,"ImageTags":{"Thumb":"t"}}],"TotalRecordCount":1}""",
            """{"Items":[{"Id":"episode","Type":"Episode","ImageTags":{"Thumb":"t"}}],"TotalRecordCount":1}""",
            """{"Items":[{"Id":"poster","Type":"Movie","ImageTags":{"Primary":"p"}}],"TotalRecordCount":1}"""
        )
        for (response in responses) MediaServerClientTest.Fixture { _, _, _ -> MediaServerClientTest.Reply(body = response.toByteArray()) }.use { fixture ->
            val account = MediaServerAccount("test", "Test", fixture.url, "fake", "emby", "user1")
            MediaServerHttp(account).use { http -> assertEquals(0, EmbyClient(account, http).folderArtwork("folder").getJSONObject("image_variants").length()) }
        }
    }

    @Test fun folderArtworkRequiresUserAccessAndValidIdentity() {
        MediaServerClientTest.Fixture { _, _, _ -> MediaServerClientTest.Reply(401, body = byteArrayOf()) }.use { fixture ->
            val account = MediaServerAccount("test", "Test", fixture.url, "fake", "emby", "user1")
            MediaServerHttp(account).use { http ->
                val client = EmbyClient(account, http)
                assertEquals("Server authentication required", assertThrows(MediaServerFailure::class.java) { client.folderArtwork("folder") }.code)
                assertThrows(MediaServerFailure::class.java) { client.folderArtwork("../private") }
            }
        }
    }

    @Test fun allSortFieldsSupportEitherDirectionAndRetainTheFolderAndPage() {
        var last = ""
        MediaServerClientTest.Fixture { request, _, _ -> last = request; MediaServerClientTest.Reply(body = """{"Items":[],"TotalRecordCount":0}""".toByteArray()) }.use { fixture ->
            val account = MediaServerAccount("test", "Test", fixture.url, "fake", "emby", "user1")
            MediaServerHttp(account).use { http ->
                val client = EmbyClient(account, http)
                for ((sort, remote) in mapOf("title" to "SortName", "created_at" to "DateCreated", "date" to "PremiereDate", "duration" to "Runtime", "rating100" to "CommunityRating")) {
                    for (direction in listOf("ASC", "DESC")) {
                        client.browse(JSONObject().put("sort", sort).put("direction", direction).put("mode", "folders").put("parent_id", "folder").put("page", 2))
                        val args = query(last)
                        assertEquals(remote, args["SortBy"]); assertEquals(if (direction == "ASC") "Ascending" else "Descending", args["SortOrder"])
                        assertEquals("folder", args["ParentId"]); assertEquals("48", args["StartIndex"]); assertEquals("false", args["Recursive"])
                    }
                }
            }
        }
    }

    @Test fun libraryHomeAddsUserScopedHistoryAndActorResultsHaveNoParentRestriction() {
        val requests = java.util.concurrent.CopyOnWriteArrayList<String>()
        MediaServerClientTest.Fixture { request, _, _ ->
            requests.add(request)
            val data = if (request.contains("/Views")) """{"Items":[
                {"Id":"movies","Name":"Movies","Type":"CollectionFolder","CollectionType":"movies","ImageTags":{"Thumb":"lib-tag"}},
                {"Id":"shows","Name":"Shows","Type":"CollectionFolder","CollectionType":"tvshows"},
                {"Id":"music","Name":"Music","Type":"CollectionFolder","CollectionType":"music"}]}"""
            else """{"Items":[],"TotalRecordCount":0}"""
            MediaServerClientTest.Reply(body = data.toByteArray())
        }.use { fixture ->
            val account = MediaServerAccount("test", "Test", fixture.url, "fake", "emby", "user1")
            MediaServerHttp(account).use { http ->
                val client = EmbyClient(account, http)
                val home = client.home(JSONObject())
                assertEquals(2, requests.size); assertEquals(2, home.getJSONArray("libraries").length())
                assertEquals("DatePlayed", query(requests.last())["SortBy"])
                assertEquals("true", query(requests.last())["EnableUserData"])
                assertFalse(query(requests.last()).containsKey("ParentId"))
                val library = home.getJSONArray("libraries").getJSONObject(0)
                assertEquals("Thumb", library.getJSONObject("cover_image").getString("image_type"))
                assertEquals("movies", library.getString("collection_type")); assertFalse(library.has("uri"))
                client.browse(JSONObject("""{"mode":"library","collection_type":"tvshows","library_id":"shows"}"""))
                assertEquals("Series", query(requests.last())["IncludeItemTypes"])
                assertEquals("shows", query(requests.last())["ParentId"])
                client.browse(JSONObject("""{"all_libraries":true,"library_id":"movies","parent_id":"folder1","performers":["person1"],"page":2}"""))
                val q = query(requests.last())
                assertFalse(q.containsKey("ParentId")); assertEquals("person1", q["PersonIds"])
                assertEquals("user1", URI("http://test" + requests.last().split(' ')[1]).path.split('/')[2])
                assertEquals("48", q["StartIndex"])
            }
        }
    }

    @Test fun homeHistoryIncludesCompletedAndUnfinishedVideosButNotUnopenedItems() {
        MediaServerClientTest.Fixture { request, _, _ ->
            val data = if (request.contains("/Views")) """{"Items":[{"Id":"lib","Name":"Movie","Type":"CollectionFolder"}]}"""
            else """{"Items":[
                {"Id":"complete","Name":"Complete","Type":"Movie","UserData":{"Played":true,"PlaybackPositionTicks":0}},
                {"Id":"resume","Name":"Resume","Type":"Video","RunTimeTicks":600000000,"UserData":{"PlaybackPositionTicks":300000000}},
                {"Id":"zero","Name":"Started","Type":"Episode","UserData":{"LastPlayedDate":"2026-10-13T01:00:00Z","PlaybackPositionTicks":0}},
                {"Id":"new","Name":"Never opened","Type":"Movie","UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"Played":false}}]}"""
            MediaServerClientTest.Reply(body = data.toByteArray())
        }.use { fixture ->
            val account = MediaServerAccount("test", "Test", fixture.url, "fake", "emby", "user1")
            MediaServerHttp(account).use { http ->
                val home = EmbyClient(account, http).home(JSONObject())
                assertEquals(listOf("complete", "resume", "zero"), home.getJSONArray("recent_opened").objects().map { it.getString("id") })
                assertEquals(listOf("resume"), home.getJSONArray("resume").objects().map { it.getString("id") })
                assertEquals(1, home.getJSONArray("libraries").length())
            }
        }
    }

    @Test fun failedOptionalHistoryKeepsLibrariesButAuthFailureStillRequiresLogin() {
        for (status in listOf(500, 401)) MediaServerClientTest.Fixture { request, _, _ ->
            if (request.contains("/Views")) MediaServerClientTest.Reply(body = """{"Items":[{"Id":"lib","Name":"Movie","Type":"CollectionFolder"}]}""".toByteArray())
            else MediaServerClientTest.Reply(status, body = byteArrayOf())
        }.use { fixture ->
            val account = MediaServerAccount("test", "Test", fixture.url, "fake", "emby", "user1")
            MediaServerHttp(account).use { http ->
                val client = EmbyClient(account, http)
                if (status == 401) assertEquals("Server authentication required", assertThrows(MediaServerFailure::class.java) { client.home(JSONObject()) }.code)
                else { val home = client.home(JSONObject()); assertEquals(1, home.getJSONArray("libraries").length()); assertTrue(home.has("recent_error")) }
            }
        }
    }

    @Test fun detailKeepsCastArtworkAndFormatWithoutServerPaths() {
        val overview = "A complete overview paragraph. ".repeat(200)
        val item = """{"Id":"film1","Name":"Film","Type":"Movie","Overview":${JSONObject.quote(overview)},"ImageTags":{"Primary":"poster-tag","Thumb":"thumb-tag"},
            "BackdropImageTags":["backdrop0","backdrop1"],"Video3DFormat":"HalfSideBySide",
            "MediaSources":[{"Path":"/private/film.mp4","Video3DFormat":"FullTopAndBottom"}],
            "People":[{"Id":"actor1","Name":"Actor","Type":"Actor","Role":"Lead","PrimaryImageTag":"face-tag"},
                {"Id":"director1","Name":"Director","Type":"Director"}],"Chapters":[{"Name":"Opening","StartPositionTicks":30000000}]}"""
        MediaServerClientTest.Fixture { request, _, _ ->
            MediaServerClientTest.Reply(body = (if (request.contains("/Images")) """[
                {"ImageType":"Backdrop","ImageIndex":1,"Path":"/private/fanart.jpg"},
                {"ImageType":"Screenshot","ImageIndex":0}, {"ImageType":"Screenshot","ImageIndex":1},
                {"ImageType":"Unsupported","ImageIndex":0}]""" else item).toByteArray())
        }.use { fixture ->
            val account = MediaServerAccount("test", "Test", fixture.url, "fake", "emby", "user1")
            MediaServerHttp(account).use { http ->
                val client = EmbyClient(account, http); val detail = client.detail("film1")
                assertEquals("FullTopAndBottom", detail.getString("video_3d_format"))
                assertEquals("film.mp4", detail.getString("basename")); assertFalse(detail.toString().contains("/private"))
                assertEquals(overview, detail.getString("description"))
                assertEquals("thumb-tag", detail.getJSONObject("image_variants").getJSONObject("Thumb").getString("image_tag"))
                assertEquals("poster-tag", detail.getJSONObject("image_variants").getJSONObject("Primary").getString("image_tag"))
                val actor = detail.getJSONArray("actors").getJSONObject(0)
                assertEquals(1, detail.getJSONArray("actors").length()); assertEquals("Lead", actor.getString("role"))
                assertEquals("face-tag", actor.getJSONObject("cover_image").getString("image_tag"))
                val images = detail.getJSONArray("images").objects()
                assertEquals(6, images.size); assertEquals(2, images.count { it.getString("image_type") == "Screenshot" })
                assertEquals(1, images.count { it.getString("image_type") == "Backdrop" && it.getInt("image_index") == 1 })
                val backdrop = images.first { it.getString("image_type") == "Backdrop" && it.getInt("image_index") == 1 }
                assertEquals("backdrop1", backdrop.getString("image_tag")); assertEquals(3000L, detail.getJSONArray("markers").getJSONObject(0).getLong("position_ms"))
                val link = client.image("film1", "Screenshot", 1, "a & b", 1024)
                assertEquals("/Items/film1/Images/Screenshot/1", link.path)
                assertEquals("a & b", URLDecoder.decode(link.rawQuery.substringAfter("tag="), "UTF-8"))
                assertThrows(MediaServerFailure::class.java) { client.image("film1", "../Primary", 0, "", 512) }
                assertThrows(MediaServerFailure::class.java) { client.image("film1", "Backdrop", -1, "", 512) }
                assertThrows(MediaServerFailure::class.java) { client.image("film1", "Primary", 0, "", 0) }
            }
        }
    }

    @Test fun missingImageEnumerationFallsBackButAuthenticationStillFails() {
        for (status in listOf(404, 401)) MediaServerClientTest.Fixture { request, _, _ ->
            if (request.contains("/Images")) MediaServerClientTest.Reply(status, body = byteArrayOf())
            else MediaServerClientTest.Reply(body = """{"Id":"film1","Type":"Movie","ImageTags":{"Primary":"p"},"Video3DFormat":"MVC"}""".toByteArray())
        }.use { fixture ->
            val account = MediaServerAccount("test", "Test", fixture.url, "fake", "emby", "user1")
            MediaServerHttp(account).use { http ->
                val client = EmbyClient(account, http)
                if (status == 401) assertEquals("Server authentication required", assertThrows(MediaServerFailure::class.java) { client.detail("film1") }.code)
                else { val detail = client.detail("film1"); assertEquals(1, detail.getJSONArray("images").length()); assertEquals("MVC", detail.getString("video_3d_format")) }
            }
        }
    }

    @Test fun stackedCdPartsHaveDistinctPlayableIdentitiesAndTheirOwnFormats() {
        var additionalQuery: Map<String, String> = emptyMap()
        MediaServerClientTest.Fixture { request, _, _ ->
            val data = when {
                request.contains("/AdditionalParts") -> {
                    additionalQuery = query(request)
                    """{"Items":[{"Id":"cd2","Name":"Same Film","Type":"Movie","Path":"/private/Film_180-cd2.mp4","Video3DFormat":"FullSideBySide","ImageTags":{"Thumb":"cd2-thumb"}}]}"""
                }
                request.contains("/Images") -> "[]"
                request.contains("/PlaybackInfo") -> """{"MediaSources":[{"Id":"source-cd2","Protocol":"File","Size":100}]}"""
                else -> """{"Id":"cd1","Name":"Same Film","Type":"Movie","PartCount":2,"MediaSources":[{"Path":"/private/Film_180-cd1.mp4","Video3DFormat":"HalfSideBySide"}]}"""
            }
            MediaServerClientTest.Reply(body = data.toByteArray())
        }.use { fixture ->
            val account = MediaServerAccount("test", "Test", fixture.url, "fake", "emby", "user1")
            MediaServerHttp(account).use { http ->
                val client = EmbyClient(account, http); val detail = client.detail("cd1")
                val parts = detail.getJSONArray("parts").objects()
                assertEquals("user1", additionalQuery["UserId"]); assertTrue(additionalQuery["Fields"].orEmpty().contains("Path"))
                assertEquals(2, parts.size); assertEquals(listOf("cd1", "cd2"), parts.map { it.getString("part_label") })
                assertEquals(listOf("medialib://test/scene/cd1", "medialib://test/scene/cd2"), parts.map { it.getString("uri") })
                assertEquals("FullSideBySide", parts[1].getString("video_3d_format"))
                assertEquals("cd2", parts[1].getJSONObject("part_image").getString("id"))
                assertEquals("cd2-thumb", parts[1].getJSONObject("part_image").getString("image_tag"))
                assertEquals("true", additionalQuery["EnableImages"])
                assertEquals("Film_180-cd2.mp4", parts[1].getString("basename")); assertFalse(detail.toString().contains("/private"))
                assertEquals("/Videos/cd2/stream", client.stream("cd2").url.path)
            }
        }
    }

    @Test fun numericPartOrderIncludesMainFileAndDoesNotUseVrOrResolutionNumbers() {
        MediaServerClientTest.Fixture { request, _, _ ->
            val data = when {
                request.contains("/AdditionalParts") -> """{"Items":[
                    {"Id":"unknown-a","Name":"Unknown","Path":"/private/2026_VR180_8K.mp4"},
                    {"Id":"ten","Name":"Film","Path":"/private/2026_VR180_8K-CD10.mp4"},
                    {"Id":"one","Name":"Film","Path":"/private/2026_VR180_8K-cd1.mp4"},
                    {"Id":"two","Name":"Film","Path":"/private/2026_VR180_8K-cd02.mp4"},
                    {"Id":"two-tie","Name":"Film","Path":"/private/2026_VR180_8K-disc2.mp4"},
                    {"Id":"five","Name":"Film - part5"},
                    {"Id":"unknown-b","Name":"Unknown 1080","Path":"/private/VR360_1080.mp4"}]}"""
                request.contains("/Images") -> "[]"
                else -> """{"Id":"three","Name":"Film","Type":"Movie","PartCount":8,"Path":"/private/2026_VR180_8K-cd3.mp4"}"""
            }
            MediaServerClientTest.Reply(body = data.toByteArray())
        }.use { fixture ->
            val account = MediaServerAccount("test", "Test", fixture.url, "fake", "emby", "user1")
            MediaServerHttp(account).use { http ->
                val parts = EmbyClient(account, http).detail("three").getJSONArray("parts").objects()
                assertEquals(listOf("one", "two", "two-tie", "three", "five", "ten", "unknown-a", "unknown-b"), parts.map { it.getString("id") })
                assertEquals(listOf(1L, 2L, 2L, 3L, 5L, 10L), parts.take(6).map { it.getLong("part_number") })
                assertFalse(parts[6].has("part_number")); assertFalse(parts[7].has("part_number"))
                assertEquals("medialib://test/scene/one", parts[0].getString("uri"))
            }
        }
    }
}
