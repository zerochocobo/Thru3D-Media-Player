package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.net.URI
import java.util.UUID

/** Native-only transient fields. Passwords and challenge data are never snapshots. */
internal class ThunderAuth(private val call: (JSONObject, CloudCancellation) -> JSONObject = { body, cancellation ->
    OpenListBackend.request("POST", "/thunder-auth", body, cancellation).getJSONObject("data")
}) {
    private val cancellation = CloudCancellation()
    private val device = UUID.randomUUID().toString().replace("-", "")
    private var creditKey = ""
    private var captchaToken = ""
    private var identity = ""
    private var pending = false
    fun login(username: String, password: String): JSONObject {
        check(!cancellation.cancelled)
        require(username.isNotBlank() && password.isNotEmpty())
        val normalized = username.trim()
        if (identity != normalized) { creditKey = ""; captchaToken = ""; identity = normalized }
        val result = call(JSONObject().put("username", username.trim()).put("password", password)
            .put("device_id", device).put("credit_key", creditKey).put("captcha_token", captchaToken), cancellation)
        check(!cancellation.cancelled)
        require(result.getString("device_id") == device)
        pending = result.has("challenge")
        if (pending) {
            val challenge = result.getJSONObject("challenge")
            require(challenge.getString("kind") in setOf("review", "captcha") && allowed(challenge.getString("url")))
        }
        return result
    }
    fun verified(result: JSONObject) {
        check(pending && !cancellation.cancelled)
        val credit = result.optString("credit_key")
        val captcha = result.optString("captcha_token")
        require((credit.isNotEmpty() || captcha.isNotEmpty()) && credit.length <= 8192 && captcha.length <= 8192)
        creditKey = credit; captchaToken = captcha; pending = false
    }
    fun close() { cancellation.cancel(); creditKey = ""; captchaToken = ""; identity = ""; pending = false }
    companion object {
        fun allowed(raw: String): Boolean = runCatching {
            val uri = URI(raw); val host = uri.host?.lowercase() ?: return false
            uri.scheme == "https" && uri.rawUserInfo == null && uri.port == -1 &&
                (host == "xunlei.com" || host.endsWith(".xunlei.com") || host == "xl.com" || host.endsWith(".xl.com"))
        }.getOrDefault(false)
        fun credential(value: JSONObject): JSONObject {
            require(value.optString("refresh_token").length in 1..16384 && value.optString("device_id").matches(Regex("[a-f0-9]{32}")))
            return JSONObject().put("root_folder_id", "")
                .put("refresh_token", value.getString("refresh_token")).put("device_id", value.getString("device_id"))
                .put("captcha_token", value.optString("captcha_token"))
        }
    }
}
