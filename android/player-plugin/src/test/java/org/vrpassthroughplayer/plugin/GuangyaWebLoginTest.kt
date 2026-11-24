package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class GuangyaWebLoginTest {
    @Test fun storePackagesUseTheirRegisteredClients() {
        assertEquals("av7r1lQqdEuV1Er3", GuangyaWebLogin.clientId("com.thru3d.quest"))
        assertEquals("av7rsoJS2g0dIaXH", GuangyaWebLogin.clientId("com.wapok.thru3d"))
    }
    @Test fun authorizeUrlCarriesPkceAndRegisteredRedirect() {
        val url = GuangyaWebLogin.authorizeUrl("av7rsoJS2g0dIaXH", "challenge", "state")
        assertTrue(url.startsWith("https://www.guangyapan.com/oauth/?client_id=av7rsoJS2g0dIaXH&response_type=code"))
        assertTrue("scope=user%20offline" in url && "code_challenge=challenge" in url && "code_challenge_method=S256" in url)
        assertTrue("redirect_uri=thru3d%3A%2F%2Foauth%2Fguangyapan" in url && url.endsWith("&state=state"))
    }
    @Test fun callbackIsRecognisedAndParsed() {
        val value = "thru3d://oauth/guangyapan?code=a%2Bb&state=s1"
        assertTrue(GuangyaWebLogin.callback(value))
        assertFalse(GuangyaWebLogin.callback("thru3d://oauth/guangyapanx?code=1"))
        assertFalse(GuangyaWebLogin.callback("https://www.guangyapan.com/?redirect=thru3d://oauth/guangyapan"))
        assertEquals(mapOf("code" to "a+b", "state" to "s1"), GuangyaWebLogin.parameters(value))
    }
    @Test fun mainFrameStaysOnGuangyapan() {
        assertTrue(GuangyaWebLogin.allowed("https://www.guangyapan.com/oauth/#/oauth/login", true))
        assertFalse(GuangyaWebLogin.allowed("https://guangyapan.com.example/oauth/", true))
        assertFalse(GuangyaWebLogin.allowed("http://www.guangyapan.com/oauth/", true))
        assertTrue(GuangyaWebLogin.allowed("https://captcha.example/frame", false))
        assertTrue(GuangyaWebLogin.allowed("about:blank", false))
    }
    @Test fun additionKeepsOnlyTheRefreshCredential() {
        val addition = GuangyaWebLogin.addition(JSONObject().put("client_id", "av7rsoJS2g0dIaXH").put("refresh_token", "r"))
        assertEquals("r", addition.getString("refresh_token"))
        assertEquals("", addition.getString("root_folder_id"))
        assertThrows(IllegalArgumentException::class.java) {
            GuangyaWebLogin.addition(JSONObject().put("client_id", "other").put("refresh_token", "r"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            GuangyaWebLogin.addition(JSONObject().put("client_id", "av7r1lQqdEuV1Er3"))
        }
    }
    @Test fun releaseProviderUsesTokenMount() {
        assertFalse(CloudDrive.TRIAL_PROVIDERS.containsKey(CloudDrive.GUANGYA))
        assertEquals("光鸭云盘", CloudDrive.PROVIDERS[CloudDrive.GUANGYA])
        assertTrue(OpenListBackend.supported(CloudDrive.GUANGYA))
        assertEquals(listOf("source"), (0 until CloudLibrary.sortOrders(CloudDrive.GUANGYA).length()).map { CloudLibrary.sortOrders(CloudDrive.GUANGYA).getString(it) })
        assertEquals(100, CloudPaging.defaultSize(CloudDrive.GUANGYA))
    }
}
