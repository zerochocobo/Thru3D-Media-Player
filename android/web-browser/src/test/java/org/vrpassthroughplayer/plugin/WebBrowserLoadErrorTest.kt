package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mozilla.geckoview.WebRequestError
import java.io.File
import java.util.Base64

class WebBrowserLoadErrorTest {
    private val root = generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "app/godot/i18n").isDirectory }

    @Test fun reasonsNameTheFailure() {
        assertEquals("dns", WebBrowserLoadError.reason(WebRequestError.ERROR_UNKNOWN_HOST))
        assertEquals("offline", WebBrowserLoadError.reason(WebRequestError.ERROR_OFFLINE))
        assertEquals("timeout", WebBrowserLoadError.reason(WebRequestError.ERROR_NET_TIMEOUT))
        assertEquals("certificate", WebBrowserLoadError.reason(WebRequestError.ERROR_SECURITY_BAD_CERT))
        assertEquals("secure", WebBrowserLoadError.reason(WebRequestError.ERROR_SECURITY_SSL))
        assertEquals("proxy", WebBrowserLoadError.reason(WebRequestError.ERROR_UNKNOWN_PROXY_HOST))
        assertEquals("blocked", WebBrowserLoadError.reason(WebRequestError.ERROR_SAFEBROWSING_PHISHING_URI))
        assertEquals("unknown", WebBrowserLoadError.reason(WebRequestError.ERROR_UNKNOWN))
        assertEquals("Server not found", WebBrowserLoadError.label("dns"))
        assertEquals("Unable to load page", WebBrowserLoadError.label("unknown"))
    }

    @Test fun httpErrorsAreClassedFrom400() {
        assertEquals("", WebBrowserLoadError.httpLabel(200))
        assertEquals("", WebBrowserLoadError.httpLabel(304))
        assertEquals("Page not found", WebBrowserLoadError.httpLabel(404))
        assertEquals("Access denied", WebBrowserLoadError.httpLabel(403))
        assertEquals("Sign-in required", WebBrowserLoadError.httpLabel(401))
        assertEquals("Too many requests", WebBrowserLoadError.httpLabel(429))
        assertEquals("Request error", WebBrowserLoadError.httpLabel(418))
        assertEquals("Server error", WebBrowserLoadError.httpLabel(503))
    }

    @Test fun everyLabelIsTranslatedAndMatchesTheToolbar() {
        // The catalog has unrelated duplicate keys that org.json rejects: read each language's lines.
        val text = File(root, "app/godot/i18n/translations.json").readText()
        val sections = listOf("zh", "zh_Hant", "ja").associateWith { language ->
            text.replace("\r\n", "\n").substringAfter("\n  \"$language\": {").substringBefore("\n  }") }
        val labels = WebBrowserLoadError.labels.values + listOf("Unable to load page", "Retry", "Page stopped") +
            listOf(404, 401, 403, 429, 418, 500).map(WebBrowserLoadError::httpLabel)
        for (language in listOf("zh", "zh_Hant", "ja")) for (label in labels)
            assertTrue("$language: $label", Regex("\n    " + Regex.escape(JSONObject.quote(label)) + ": \"[^\"]+\"").containsMatchIn(sections.getValue(language)))
        // web_browser_panel.gd keeps the same reason keys for the address bar.
        val panel = File(root, "app/godot/scripts/web_browser_panel.gd").readText()
        val godot = Regex("\"([a-z]+)\": \"([^\"]+)\"").findAll(panel.substringAfter("const LOAD_ERRORS := {").substringBefore("}"))
            .associate { it.groupValues[1] to it.groupValues[2] }
        assertEquals(WebBrowserLoadError.labels, godot)
    }

    @Test fun errorPageIsDarkEscapedAndOnlyReloads() {
        val html = WebBrowserLoadError.html("Server not found", "<evil>.test", "category=network code=0x25", "Retry")
        assertTrue(html.contains("background:#1b1d22"))
        assertTrue(html.contains("&lt;evil&gt;.test"))
        assertFalse(html.contains("<evil>"))
        assertEquals(1, Regex("<button").findAll(html).count())
        assertTrue(html.contains("onclick=\"location.reload()\""))
        assertFalse(html.contains("addCertException"))
        val page = WebBrowserLoadError.page("找不到服务器", "www.bilibili.com", "", "重试")
        assertTrue(page.startsWith("data:text/html;charset=utf-8;base64,"))
        val decoded = String(Base64.getDecoder().decode(page.substringAfter("base64,")), Charsets.UTF_8)
        assertTrue(decoded.contains("<h1>找不到服务器</h1>") && decoded.contains("www.bilibili.com"))
    }
}
