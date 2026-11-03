package org.vrpassthroughplayer.plugin

import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class PlexLibraryUiLiveTest {
    @Test fun galleryContractAndArtworkUseTheRealServer() {
        val base = System.getenv("VRPP_PLEX_TEST_URL").orEmpty()
        val token = System.getenv("VRPP_PLEX_TEST_TOKEN").orEmpty()
        assumeTrue("Optional Plex library UI integration", base.isNotBlank() && token.isNotBlank())
        val id = System.getenv("VRPP_PLEX_BROWSER_TEST_ITEM").orEmpty().ifBlank { "4" }
        val account = MediaServerAccount("profile", "Plex", base, token, "plex")
        MediaServerHttp(account).use { http ->
            val client = PlexClient(account, http)
            val home = client.home(JSONObject())
            assertEquals("libraries", home.getJSONObject("capabilities").getString("home_layout"))
            assertTrue(home.getJSONObject("capabilities").getBoolean("artwork"))
            val libraries = home.getJSONArray("libraries"); assertTrue(libraries.length() > 0)
            val library = libraries.getJSONObject(0)
            val wall = client.browse(JSONObject().put("library_id", library.getString("id")).put("mode", "library"))
            assertTrue(wall.getJSONArray("entries").length() > 0)
            val detail = client.detail(id)
            assertTrue(detail.getJSONObject("image_variants").has("Primary"))
            assertTrue(detail.getJSONArray("backdrops").length() > 0)
            assertFalse(detail.toString().contains(token)); assertFalse(home.toString().contains(token))
            val output = System.getenv("VRPP_PLEX_UI_OUTPUT").orEmpty().takeIf(String::isNotBlank)?.let { File(it).apply { mkdirs() } }
            val previews = JSONObject()
            val artwork = listOf("poster" to detail.getJSONObject("image_variants").getJSONObject("Primary"),
                "backdrop" to detail.getJSONObject("image_variants").getJSONObject("Backdrop"), "library" to library.getJSONObject("cover_image")) +
                detail.getJSONArray("actors").objects().filter { it.optBoolean("has_cover") }.take(5).map {
                    "actor-${it.getString("id")}" to it.getJSONObject("cover_image")
                }
            for ((name, node) in artwork) {
                val image = client.image(node.getString("id"), node.getString("image_type"), 0, node.getString("image_tag"), 512)
                assertTrue(account.accepts(image)); assertFalse(image.toString().contains(token))
                val bytes = http.bytes(image, 8 * 1024 * 1024)
                val png = bytes.size > 8 && bytes[0] == 0x89.toByte() && bytes[1] == 0x50.toByte()
                val jpeg = bytes.size > 2 && bytes[0] == 0xff.toByte() && bytes[1] == 0xd8.toByte()
                assertTrue("Server must return JPEG or PNG artwork", png || jpeg)
                output?.resolve("$name.${if (png) "png" else "jpg"}")?.let { file -> file.writeBytes(bytes); previews.put(name, file.absolutePath) }
                println("Plex live UI $name: authenticated server artwork received")
            }
            // The preview contains only this explicitly selected sample, never the full library.
            output?.resolve("presentation.json")?.writeText(JSONObject().put("home", home.apply {
                put("recent_opened", org.json.JSONArray()); put("resume", org.json.JSONArray())
            }).put("detail", detail).put("preview_images", previews).toString(2))
            println("Plex live UI: library cards, poster wall and rich detail contract verified")
        }
    }
}
