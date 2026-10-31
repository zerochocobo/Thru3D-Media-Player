package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class QuarkWebLoginTest {
    private val nonce = "abcdefghijklmnop12345678"
    private val target = "https://pan.quark.cn/open/v1/oauth/authorize?client_id=fixture-client&state=com.trim.cloudstorage--trimNonce__$nonce&redirect_uri=https%3A%2F%2Foauth.fnnas.com%2Fapi%2Fv1%2Fredirect%2FfromQuark"
    @Test fun publicRequestOnlyAcceptsTheBoundProviderGrant() {
        assertEquals(target, OpenListLoginExchange.authorizationTarget(JSONObject().put("text", target), CloudDrive.QUARK))
        for (url in listOf("https://pan.quark.cn/", "https://oauth.fnnas.com/", "http://pan.quark.cn/open/v1/oauth/authorize",
            target.replace("pan.quark.cn", "pan.quark.cn.evil.invalid"), target.replace(nonce, "short"),
            target.replace("fixture-client", "x"), target.replace("oauth.fnnas.com", "elsewhere.invalid"),
            target + "&state=duplicate", target + "&padding=" + "x".repeat(16384))) {
            assertTrue(runCatching { OpenListLoginExchange.authorizationTarget(JSONObject().put("text", url), CloudDrive.QUARK) }.isFailure)
        }
    }
    @Test fun isolatedLoginKeepsTheExistingBrokerStateAndAppBinding() {
        val flow = OpenListOAuthSession(CloudDrive.QUARK)
        flow.providerNavigation(OpenListLoginExchange.authorizationTarget(JSONObject().put("text", target), CloudDrive.QUARK), "")
        val callback = "https://api.oplist.org/quarkyun/callback?nonce=returnednonce0123456789"
        assertFalse(flow.allowCallback(callback))
        assertTrue(runCatching { flow.providerNavigation("https://oauth.fnnas.com/api/v1/redirect/fromQuark?code=fixture&state=wrong", "") }.isFailure)
        flow.providerNavigation("https://oauth.fnnas.com/api/v1/redirect/fromQuark?code=fixture&state=com.trim.cloudstorage--trimNonce__$nonce", "")
        assertTrue(flow.allowCallback(callback))
        assertTrue(flow.matchesCallback(callback))
        assertFalse(flow.matchesCallback(callback + "other"))
        val fields = JSONObject().put("accessToken", "fixture-access").put("refreshToken", "fixture-refresh")
            .put("appId", "other-client").put("signKey", "fixture-sign")
        val response = JSONObject().put("code", 0).put("data", fields)
        assertNull(flow.quarkCredential(response))
        fields.put("appId", "fixture-client")
        assertNotNull(flow.quarkCredential(response))
        assertNull(OpenListOAuthSession(CloudDrive.QUARK).quarkCredential(response))
    }
}
