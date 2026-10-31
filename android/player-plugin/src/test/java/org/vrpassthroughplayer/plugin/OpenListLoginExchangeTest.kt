package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.Base64

class OpenListLoginExchangeTest {
    private class Response(private val code: Int, private val body: String = "",
        private val headers: Map<String, List<String>> = emptyMap()) : HttpURLConnection(URL(OpenListAuth.ORIGIN)) {
        var released = false
        override fun getResponseCode() = code
        override fun getInputStream() = ByteArrayInputStream(body.toByteArray())
        override fun getHeaderFields() = headers
        override fun getHeaderField(name: String) = headers.entries.firstOrNull { it.key.equals(name, true) }?.value?.firstOrNull()
        override fun disconnect() { released = true }
        override fun usingProxy() = false
        override fun connect() {}
    }

    @Test fun everyProviderKeepsItsAttemptCookiesAndConsumesTokensWithoutLoadingTheResultPage() {
        val variants = mapOf(CloudDrive.OPEN115 to "115cloud_go", CloudDrive.BAIDU to "baiduyun_go",
            CloudDrive.ALIYUN to "alicloud_go", CloudDrive.ONEDRIVE to "onedrive_pr")
        val hosts = mapOf(CloudDrive.OPEN115 to "passportapi.115.com", CloudDrive.BAIDU to "openapi.baidu.com",
            CloudDrive.ALIYUN to "openapi.aliyundrive.com", CloudDrive.ONEDRIVE to "login.microsoftonline.com")
        for ((provider, variant) in variants) {
            val callback = OpenListAuth.ORIGIN + "/" + variant.substringBefore('_') + "/callback"
            val target = "https://${hosts.getValue(provider)}/authorize?redirect_uri=" + java.net.URLEncoder.encode(callback, "UTF-8")
            val fields = JSONObject().put("driver_txt", variant).put("server_use", true)
                .put("access_token", "fixture-access").put("refresh_token", "fixture-refresh")
            val result = "/#" + Base64.getEncoder().encodeToString(fields.toString().toByteArray())
            val first = Response(200, JSONObject().put("text", target).toString(), mapOf("Set-Cookie" to
                listOf("driver_txt=$variant; Path=/", "server_use=true; Path=/", "random_key=fixture-state; Path=/")))
            val second = Response(302, headers = mapOf("Location" to listOf(result)))
            val calls = mutableListOf<URI>()
            val transport = OpenListLoginExchange(CloudCancellation()) { uri -> calls.add(uri); if (calls.size == 1) first else second }
            val flow = OpenListOAuthSession(provider)
            val prepared = flow.providerNavigation(transport.request(provider), transport.toolCookies())
            val state = URI(prepared).query.substringAfter("state=")
            assertTrue(state.isNotEmpty())
            val returned = "$callback?code=fixture-code&state=$state"
            assertTrue(flow.allowCallback(returned))
            val credential = flow.credential(transport.exchange(returned, provider))
            assertNotNull(provider, credential)
            assertEquals(provider, credential!!.provider)
            assertTrue(second.getRequestProperty("Cookie").contains("driver_txt=$variant"))
            assertTrue(second.getRequestProperty("Cookie").contains("server_use=true"))
            if (provider == CloudDrive.OPEN115) assertTrue(second.getRequestProperty("Cookie").contains("random_key=fixture-state"))
            assertEquals(listOf(URI(OpenListAuth.requestUrl(provider)), URI(returned)), calls)
            assertFalse(second.instanceFollowRedirects)
            assertTrue(first.released && second.released)
            assertFalse(OpenListOAuthSession(provider).allowCallback(returned))
            assertNull(OpenListAuth.parse(OpenListAuth.ORIGIN + result, if (provider == CloudDrive.BAIDU) CloudDrive.ONEDRIVE else CloudDrive.BAIDU))
        }
    }

    @Test fun requestAndTokenRedirectsCannotEscapeTheSelectedProviderOrToolOrigin() {
        for (target in listOf("https://evil.invalid/", "https://115.com.evil.invalid/", "http://115.com/", OpenListAuth.ORIGIN + "/", "intent://login")) {
            assertThrows(IllegalArgumentException::class.java) { OpenListLoginExchange.authorizationTarget(JSONObject().put("text", target), CloudDrive.OPEN115) }
        }
        for (target in listOf("https://evil.invalid/#token", "https://api.oplist.org.evil.invalid/#token", "/other#token", "/?x=y#token", "/", "/#" + "x".repeat(90000))) {
            assertThrows(IllegalArgumentException::class.java) { OpenListLoginExchange.tokenRedirect(OpenListAuth.ORIGIN + "/115cloud/callback", 302, target) }
        }
        assertThrows(IllegalArgumentException::class.java) { OpenListLoginExchange.tokenRedirect(OpenListAuth.ORIGIN, 200, "/#token") }
    }

    @Test fun attemptsNeverShareCookiesAndCancelledRequestsNeverStart() {
        val cancellation = CloudCancellation(); cancellation.cancel()
        var opened = false
        val transport = OpenListLoginExchange(cancellation) { opened = true; Response(200, "{}") }
        assertThrows(CloudFailure::class.java) { transport.request(CloudDrive.OPEN115) }
        assertTrue(opened) // The allocated connection is disconnected before any response is read.
        assertEquals("", OpenListLoginExchange(CloudCancellation()).toolCookies())
        val large = Response(200, "x".repeat(90001))
        assertThrows(IllegalArgumentException::class.java) { OpenListLoginExchange(CloudCancellation()) { large }.request(CloudDrive.OPEN115) }
        assertTrue(large.released)
    }
}
