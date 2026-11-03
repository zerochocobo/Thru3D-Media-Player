package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Fixture
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply

class PlexPresentationTest {
    private val movie = """{"ratingKey":"12","type":"movie","title":"Mountain journey","duration":60000,"viewOffset":1200,"thumb":"/library/metadata/12/thumb/100","art":"/library/metadata/12/art/101","summary":"A journey across the mountains.","Role":[{"id":51,"tag":"Alex","role":"Guide","thumb":"https://metadata.example/actor.jpg"}],"Genre":[{"id":20,"tag":"Adventure"}],"Media":[{"id":81,"width":3840,"height":1920,"videoResolution":"4K","videoCodec":"hevc","container":"mp4","Part":[{"id":91,"key":"/library/parts/91/1/file.mp4","file":"/private/film-4k.mp4","size":10000}]},{"id":82,"width":1920,"height":1080,"videoResolution":"1080","videoCodec":"h264","container":"mkv","Part":[{"id":92,"key":"/library/parts/92/1/file.mkv","file":"/private/film-1080.mkv","size":20000}]}]}"""
    private fun response(data: String) = Reply(body = data.toByteArray())
    private fun answer(request: String): Reply = when {
        request.contains("/library/sections?") || request.contains("/library/sections ") -> response("""{"MediaContainer":{"Directory":[{"key":"1","title":"Films","type":"movie"},{"key":"2","title":"TV","type":"show"}]}}""")
        request.contains("/library/metadata/12?") -> response("""{"MediaContainer":{"Metadata":[$movie]}}""")
        else -> response("""{"MediaContainer":{"totalSize":1,"Metadata":[$movie]}}""")
    }
    private fun run(block: (PlexClient, MutableList<String>) -> Unit) {
        val requests = mutableListOf<String>()
        Fixture { request, _, _ -> requests.add(request); answer(request) }.use { fixture ->
            val account = MediaServerAccount("profile", "Plex", fixture.url, "private-token", "plex")
            MediaServerHttp(account).use { block(PlexClient(account, it), requests) }
        }
    }
    @Test fun homeUsesSharedEmbyGalleryAndHistoryAcrossLibraries() = run { client, requests ->
        val home = client.home(JSONObject())
        val caps = home.getJSONObject("capabilities")
        assertEquals("libraries", caps.getString("home_layout")); assertTrue(caps.getBoolean("artwork"))
        assertEquals("local", caps.getString("favorite_scope")); assertFalse(caps.optBoolean("photos"))
        val libraries = home.getJSONArray("libraries")
        assertEquals(2, libraries.length()); assertEquals("movies", libraries.getJSONObject(0).getString("collection_type"))
        assertEquals("tvshows", libraries.getJSONObject(1).getString("collection_type"))
        assertEquals("section-1", libraries.getJSONObject(0).getJSONObject("cover_image").getString("id"))
        assertEquals(1, home.getJSONArray("recent_opened").length()); assertEquals(1, home.getJSONArray("resume").length())
        assertEquals("", home.getString("library_id")); assertTrue(requests.last().contains("lastViewedAt"))
        client.browse(JSONObject("""{"all_libraries":true,"performers":["51"]}"""))
        assertTrue(requests.last().contains("/library/all?")); assertTrue(requests.last().contains("actor=51"))
        client.browse(JSONObject("""{"library_id":"2","mode":"library","collection_type":"tvshows"}"""))
        assertTrue(requests.last().contains("/library/sections/2/all?")); assertTrue(requests.last().contains("type=2"))
    }
    @Test fun richDetailCarriesArtworkActorsAndStableVersionSelection() = run { client, _ ->
        val detail = client.detail("12")
        assertEquals(2, detail.getJSONArray("images").length()); assertEquals(1, detail.getJSONArray("backdrops").length())
        assertEquals(setOf("Primary", "Thumb", "Backdrop"), detail.getJSONObject("image_variants").keys().asSequence().toSet())
        val actor = detail.getJSONArray("actors").getJSONObject(0)
        assertEquals("51", actor.getString("id")); assertEquals("Guide", actor.getString("role"))
        assertEquals("actor-12-51", actor.getJSONObject("cover_image").getString("id"))
        val versions = detail.getJSONArray("versions")
        assertEquals(2, versions.length()); assertEquals("81", versions.getJSONObject(0).getString("source_id"))
        assertEquals("medialib://profile/scene/12?source=82", versions.getJSONObject(1).getString("uri"))
        assertEquals(0, versions.getJSONObject(1).getInt("position_ms"))
        assertFalse(detail.toString().contains("private-token")); assertFalse(detail.toString().contains("/private/"))
        assertFalse(detail.toString().contains("metadata.example"))
        assertEquals("/library/parts/92/1/file.mkv", client.stream("12", "82").url.path)
        assertThrows(MediaServerFailure::class.java) { client.stream("12", "999") }
    }
    @Test fun artworkRequestsStayOnPlexAndHonorImageSizesAndIdentity() = run { client, _ ->
        val image = client.image("12", "Backdrop", 0, "", 256)
        assertEquals("/photo/:/transcode", image.path)
        assertTrue(image.rawQuery.contains("width=256")); assertTrue(image.rawQuery.contains("%2Flibrary%2Fmetadata%2F12%2Fart%2F101"))
        val actor = client.image("actor-12-51", "Primary", 0, "", 128)
        assertEquals(image.host, actor.host); assertTrue(actor.rawQuery.contains("https%3A%2F%2Fmetadata.example"))
        assertFalse(actor.toString().contains("private-token"))
        assertEquals("/photo/:/transcode", client.image("section-1", "Thumb", 0, "", 512).path)
        assertThrows(MediaServerFailure::class.java) { client.image("actor-12-999", "Primary", 0, "", 128) }
        assertThrows(MediaServerFailure::class.java) { client.image("12", "Theme", 0, "", 512) }
        assertThrows(MediaServerFailure::class.java) { client.image("12", "Primary", 0, "", 4096) }
    }
}
