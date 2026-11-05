package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.net.URLDecoder

class OpenList123AuthTest {
    private val provider = CloudDrive.OPEN123
    private val authorization = "https://yun.123pan.com/auth?client_id=fixture&redirect_uri=https%3A%2F%2Fapi.oplist.org%2F123cloud%2Fcallback&scope=user%3Abase%2Cfile%3Aall%3Aread%2Cfile%3Aall%3Awrite&state=OpenList"
    private fun data() = JSONObject().put("driver_txt", "123cloud_oa").put("server_use", true)
        .put("access_token", "fixture-access").put("refresh_token", "fixture-refresh")
    private fun state(url: String) = URI(url).rawQuery.split('&').first { it.startsWith("state=") }
        .substringAfter('=').let { URLDecoder.decode(it, "UTF-8") }

    @Test fun officialFlowUsesPinnedDriverAndRefreshFields() {
        assertEquals("123云盘", CloudDrive.PROVIDERS[provider])
        assertTrue(OpenListAuth.supported(provider))
        assertTrue(OpenListBackend.supported(provider))
        assertEquals("123 Open", OpenListAuth.drivers[provider])
        assertEquals("https://api.oplist.org/123cloud/requests?client_uid=&client_key=&driver_txt=123cloud_oa&server_use=true", OpenListAuth.requestUrl(provider))
        val addition = OpenListAuth.fromData(data(), provider)!!.addition()
        assertEquals("0", addition.getString("root_folder_id"))
        assertEquals("fixture-access", addition.getString("AccessToken"))
        assertEquals("fixture-refresh", addition.getString("RefreshToken"))
        assertEquals("", addition.getString("ClientID"))
        assertEquals("", addition.getString("ClientSecret"))
        assertTrue(addition.getBoolean("use_online_api"))
        assertFalse(addition.getBoolean("DirectLink"))
        assertEquals("https://api.oplist.org/123cloud/renewapi", addition.getString("api_url_address"))
        assertEquals(100, CloudPaging.defaultSize(provider))
        assertFalse(CloudPaging.direct(provider))
        assertTrue(runCatching { CloudPaging.size(provider, 200) }.isFailure)
    }

    @Test fun personalCredentialsAndOtherProvidersCannotEnterOfficialFlow() {
        for (variant in listOf("123cloud_go", "115cloud_go", "alicloud_go"))
            assertNull(OpenListAuth.fromData(data().put("driver_txt", variant), provider))
        for (field in listOf("client_uid", "client_key", "secret_key"))
            assertNull(OpenListAuth.fromData(data().put(field, "custom"), provider))
        assertNull(OpenListAuth.fromData(data().put("server_use", false), provider))
        for (field in listOf("access_token", "refresh_token"))
            assertNull(OpenListAuth.fromData(data().put(field, ""), provider))
    }

    @Test fun fixedBrokerStateIsReplacedAndCallbacksAreBoundToOneAttempt() {
        val a = OpenListOAuthSession(provider)
        val b = OpenListOAuthSession(provider)
        val target = OpenListLoginExchange.authorizationTarget(JSONObject().put("text", authorization), provider)
        val first = a.providerNavigation(target, "")
        val firstState = state(first)
        assertNotEquals("OpenList", firstState)
        assertNotEquals(firstState, state(b.providerNavigation(target, "")))
        assertEquals(first, a.providerNavigation(target, ""))
        val callback = "https://api.oplist.org/123cloud/callback?code=fixture&state=$firstState"
        assertNull(a.recovered(data()))
        assertFalse(b.allowCallback(callback))
        assertFalse(a.allowCallback(callback.replace(firstState, "OpenList")))
        assertFalse(a.allowCallback(callback + "&state=$firstState"))
        assertFalse(a.allowCallback(callback.replace("123cloud", "115cloud")))
        assertTrue(a.allowCallback(callback))
        assertNotNull(a.recovered(data()))
        assertTrue(a.matchesCallback(callback))
        assertFalse(a.allowCallback(callback))
        assertFalse(a.callbackDiagnostics(callback).toString().contains(firstState))
        var time = 1L
        val expired = OpenListOAuthSession(provider) { time }
        val expiredState = state(expired.providerNavigation(target, ""))
        time += 1_200_000_000_001L
        assertFalse(expired.allowCallback(callback.replace(firstState, expiredState)))
    }

    @Test fun navigationRejectsFakeOriginsAndWrongGrantTargets() {
        assertTrue(OpenListAuth.allowed("https://yun.123pan.com/auth", provider, true))
        for (url in listOf("http://yun.123pan.com/auth", "https://123pan.com.evil.test/", "https://123pan.cn.evil.test/", "https://evil.test/", "https://yun.123pan.com:444/", "https://user@yun.123pan.com/", "https://115.com/"))
            assertFalse(url, OpenListAuth.allowed(url, provider, true))
        for (url in listOf(authorization.replace("/auth?", "/other?"), authorization.replace("%2F123cloud%2Fcallback", "%2F115cloud%2Fcallback"), authorization + "&client_id=other"))
            assertTrue(runCatching { OpenListLoginExchange.authorizationTarget(JSONObject().put("text", url), provider) }.isFailure)
    }

    @Test fun officialCnLoginRoundTripPreservesStateWithoutBecomingAnOAuthCallback() {
        val session = OpenListOAuthSession(provider)
        val grant = session.providerNavigation(authorization, "")
        val expectedState = state(grant)
        val back = java.net.URLEncoder.encode(grant, "UTF-8")
        for (url in listOf("https://user.123pan.cn/api/user/token/verify?redirect_url=$back",
            "https://user.123pan.cn/centerlogin?redirect_url=$back&source_page=other",
            grant.replace("yun.123pan.com", "yun.123pan.cn"))) {
            assertTrue(CloudWebNavigation.allowed(url, provider, true))
            assertTrue(CloudWebNavigation.allowed(url, provider, false))
            assertEquals(url, session.providerNavigation(url, ""))
            assertFalse(OpenListAuth.callback(url, provider))
            assertFalse(session.allowCallback(url))
            assertNull(session.recovered(data()))
        }
        assertTrue(session.allowCallback("https://api.oplist.org/123cloud/callback?code=fixture&state=$expectedState"))
        assertNotNull(session.recovered(data()))
        for (other in listOf(CloudDrive.BAIDU, CloudDrive.ALIYUN, CloudDrive.QUARK, CloudDrive.ONEDRIVE))
            assertFalse(OpenListAuth.allowed("https://user.123pan.cn/centerlogin", other, true))
    }
}
