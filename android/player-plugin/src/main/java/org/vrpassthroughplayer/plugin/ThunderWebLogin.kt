package org.vrpassthroughplayer.plugin

import android.app.Activity
import org.json.JSONObject
import java.net.URI
import java.net.URLDecoder

internal class ThunderWebLogin(host: () -> Activity?, private val challenge: JSONObject,
    private val verified: (JSONObject) -> Boolean) : AccountWebLogin {
    private var closed = false
    private var completed = false
    private val review = challenge.optJSONObject("review")?.let { data ->
        require(ThunderAuth.allowed(data.getString("reviewurl")))
        GeckoLoginVerification(data) { answer -> finish(answer) }
    }
    private val gecko = GeckoLoginSession(host, verification = review) { url, main ->
        if (closed) null else if (main && challenge.getString("kind") == "captcha" && callback(url) != null) {
            finish(callback(url)!!); null
        } else if (ThunderAuth.allowed(url)) url else null
    }
    init { require(ThunderAuth.allowed(challenge.getString("url"))) }
    private fun finish(answer: JSONObject) {
        if (!closed && !completed && verified(answer)) { completed = true; gecko.pause(true) }
    }
    private fun callback(raw: String): JSONObject? = runCatching {
        val uri = URI(raw)
        if (uri.scheme != "xlaccsdk01" || uri.host != "xunlei.com" || uri.path != "/callback") return null
        val values = uri.rawQuery.orEmpty().split('&').map { it.split('=', limit = 2) }.filter { it.size == 2 }
            .associate { URLDecoder.decode(it[0], "UTF-8") to URLDecoder.decode(it[1], "UTF-8") }
        if (values["state"] != "harbor") return null
        val token = values["captcha_token"] ?: return null
        require(token.length in 1..8192)
        JSONObject().put("captcha_token", token)
    }.getOrNull()
    override fun open() { gecko.open(challenge.getString("url")) }
    override fun snapshot(): JSONObject = gecko.snapshot()
    override fun frame(): ByteArray = ByteArray(0)
    override fun action(action: String, x: Float, y: Float, text: String) { if (!closed && !completed) gecko.action(action, x, y, text) }
    override fun pause(value: Boolean) { gecko.pause(value) }
    override fun close() { closed = true; gecko.close() }
}
