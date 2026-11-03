package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI

class JellyfinTagsTest {
    @Test fun filters2TagsHaveStablePagingSearchAndLibraryScope() {
        val requests = java.util.concurrent.CopyOnWriteArrayList<String>()
        MediaServerClientTest.Fixture { request, _, _ ->
            requests += request
            val tags = (54 downTo 0).map { "Tag %02d".format(it) } + listOf("", "Tag 00", "中文测试")
            MediaServerClientTest.Reply(body = JSONObject().put("Tags", JSONArray(tags)).toString().toByteArray())
        }.use { fixture ->
            val account = MediaServerAccount("profile", "NAS", fixture.url, "token", "jellyfin", "user")
            MediaServerHttp(account).use { http ->
                val client = EmbyClient(account, http)
                val first = client.candidates(JSONObject().put("kind", "tags").put("library_id", "library"))
                assertEquals(56, first.getInt("total")); assertEquals(48, first.getJSONArray("entries").length())
                assertEquals("Tag 00", first.getJSONArray("entries").getJSONObject(0).getString("id"))
                val second = client.candidates(JSONObject().put("kind", "tags").put("page", 2))
                assertEquals(8, second.getJSONArray("entries").length())
                val filtered = client.candidates(JSONObject().put("kind", "tags").put("q", "TAG 5"))
                assertEquals(5, filtered.getInt("total"))
                assertEquals(1, client.candidates(JSONObject().put("kind", "tags").put("q", "中文")).getInt("total"))
                assertEquals(0, client.candidates(JSONObject().put("kind", "tags").put("page", 3)).getJSONArray("entries").length())
                assertTrue(requests.all { URI(it.split(' ')[1]).path == "/Items/Filters2" })
                assertTrue(requests.first().contains("ParentId=library")); assertTrue(requests.first().contains("UserId=user"))
                assertFalse(requests.first().contains("SearchTerm=")); assertFalse(requests.first().contains("StartIndex="))
            }
        }
    }
    @Test fun embyKeepsItsNativeTagCandidates() {
        MediaServerClientTest.Fixture { request, _, _ ->
            assertEquals("/Tags", URI(request.split(' ')[1]).path)
            MediaServerClientTest.Reply(body = """{"Items":[{"Id":"id","Name":"Tag","ChildCount":3}],"TotalRecordCount":1}""".toByteArray())
        }.use { fixture ->
            val a = MediaServerAccount("profile", "NAS", fixture.url, "token", "emby", "user")
            MediaServerHttp(a).use { http -> assertEquals(3, EmbyClient(a, http).candidates(JSONObject().put("kind", "tags"))
                .getJSONArray("entries").getJSONObject(0).getInt("count")) }
        }
    }
}
