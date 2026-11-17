package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ThunderAuthTest {
    @Test fun playbackUsesExistingIdentityBoundProxy() {
        val client = OpenListBackend.Client("/12345678-1234-1234-1234-123456789abc", CloudDrive.THUNDER,
            stream = { error("Generic proxy loses the upstream gateway error") }, call = { method, route, body ->
                assertEquals("POST", method); assertEquals("/archive-stream", route)
                assertEquals("/目录/movie.mkv", body!!.getString("path"))
                assertEquals("file-id", body.getString("id")); assertEquals(100L, body.getLong("size"))
                JSONObject().put("data", JSONObject().put("stream", "http://127.0.0.1:1234/bound"))
            })
        assertEquals("http://127.0.0.1:1234/bound", client.resolve(CloudFile("movie.mkv", false, 100,
            "/目录/movie.mkv", objectId = "file-id")).url)
    }
    @Test fun betaProviderIsPublicButSeparateFromOAuth() {
        assertTrue(CloudDrive.PROVIDERS.containsKey(CloudDrive.THUNDER))
        assertFalse(CloudDrive.TRIAL_PROVIDERS.containsKey(CloudDrive.THUNDER))
        assertTrue(OpenListBackend.supported(CloudDrive.THUNDER))
        assertEquals("迅雷云盘（测试版）", CloudDrive.providerName(CloudDrive.THUNDER))
        assertFalse(OpenListAuth.supported(CloudDrive.THUNDER))
        assertEquals(100, CloudPaging.defaultSize(CloudDrive.THUNDER))
        assertEquals("[\"source\"]", CloudLibrary.sortOrders(CloudDrive.THUNDER).toString())
    }
    @Test fun browseUsesSupportedSizesAndSourceOrderAcrossFoldersAndContinuation() {
        val requests = mutableListOf<JSONObject>()
        val client = OpenListBackend.Client("/12345678-1234-1234-1234-123456789abc", CloudDrive.THUNDER,
            call = { method, route, body ->
                assertEquals("POST", method); assertEquals("/directory", route)
                requests.add(body!!)
                assertEquals("source", body.getString("order"))
                val size = body.getInt("page_size")
                assertTrue(size in listOf(48, 100))
                JSONObject().put("data", JSONObject().put("total", -1).put("next_offset", body.getInt("offset") + size)
                    .put("content", org.json.JSONArray().put(JSONObject().put("id", "file-id").put("name", "movie.mp4").put("is_dir", false))))
            })
        val order = CloudLibrary.effectiveOrder(CloudDrive.THUNDER, "name_asc")
        val oldRequest = runCatching { client.sizedPage("/", 0, false, order, 200) }.exceptionOrNull()
        assertTrue(oldRequest is IllegalArgumentException && oldRequest.message!!.contains("page size"))
        assertTrue(requests.isEmpty())
        for ((path, offset) in listOf("/" to 0, "/Folder" to 0, "/Folder" to 100)) {
            val page = client.sizedPage(path, offset, false, order, 100)
            assertEquals(100, page.pageSize); assertEquals(offset + 100, page.nextOffset)
            assertEquals("movie.mp4", page.files.single().name)
            assertEquals(path, requests.last().getString("path"))
        }
        assertEquals(48, client.sizedPage("/Folder", 0, false, order, 48).pageSize)
    }
    @Test fun challengeContinuesSameDeviceAndCannotCarryIntoAnotherAccount() {
        val requests = mutableListOf<JSONObject>()
        val auth = ThunderAuth { body, _ ->
            requests.add(body)
            JSONObject().put("device_id", body.getString("device_id")).put("challenge",
                JSONObject().put("kind", "review").put("url", "https://i.xunlei.com/xlcaptcha/android.html"))
        }
        auth.login("first", "password-one")
        auth.verified(JSONObject().put("credit_key", "fixture-credit"))
        auth.login("first", "password-one")
        assertEquals("fixture-credit", requests.last().getString("credit_key"))
        auth.login("second", "password-two")
        assertEquals("", requests.last().getString("credit_key"))
        assertEquals(requests.first().getString("device_id"), requests.last().getString("device_id"))
        auth.close()
        assertTrue(runCatching { auth.login("second", "password-two") }.isFailure)
    }
    @Test fun persistedCredentialDropsUsernamePasswordAndUnknownFields() {
        val value = ThunderAuth.credential(JSONObject().put("refresh_token", "fixture-refresh")
            .put("device_id", "a".repeat(32)).put("username", "must-not-persist-user")
            .put("password", "must-not-persist").put("access_token", "transient"))
        assertFalse(value.has("username")); assertFalse(value.has("password")); assertFalse(value.has("access_token"))
        assertTrue(ThunderAuth.allowed("https://i.xunlei.com/xlcaptcha/android.html"))
        for (url in listOf("http://i.xunlei.com/", "https://i.xunlei.com.evil.invalid/", "https://name@i.xunlei.com/", "https://i.xunlei.com:8443/"))
            assertFalse(ThunderAuth.allowed(url))
    }
    @Test fun closedSessionRejectsLateSuccessfulLogin() {
        lateinit var auth: ThunderAuth
        auth = ThunderAuth { body, _ ->
            auth.close()
            JSONObject().put("device_id", body.getString("device_id")).put("credential", JSONObject())
        }
        assertTrue(runCatching { auth.login("fixture", "fixture-password") }.isFailure)
    }
}
