package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import org.vrpassthroughplayer.plugin.CloudLoginFailure.Stage
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/** GuangYaPan Web OAuth + PKCE. The registered thru3d:// redirect never leaves Gecko:
 * its load request is consumed here, and only the code exchange reaches the core. */
internal class GuangyaWebLogin(private val host: () -> Activity?, private val authorized: (JSONObject) -> Boolean,
    private val exchange: ((JSONObject, CloudCancellation) -> JSONObject)? = null) : AccountWebLogin {
    private val ui = Handler(Looper.getMainLooper())
    @Volatile private var closed = false
    @Volatile private var paused = false
    @Volatile private var status = "Loading…"
    @Volatile private var errorCode = ""
    @Volatile private var gecko: GeckoLoginSession? = null
    private var epoch = 0L
    private var exchanging = false
    private var started = false
    private var http = CloudCancellation()
    private var pkce = Pkce()

    private class Pkce {
        val verifier = random(48)
        val state = random(24)
        val challenge: String = encode(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII)))
        private companion object {
            fun encode(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
            fun random(size: Int) = encode(ByteArray(size).also(SecureRandom()::nextBytes))
        }
    }

    override fun snapshot(): JSONObject {
        val code = errorCode
        return (gecko?.snapshot() ?: JSONObject().put("renderer", "gecko")).apply {
            put("status", if (code.isEmpty()) status else "Authorization failed. Try again.")
            if (code.isNotEmpty()) put("failed", true).put("error_code", code)
            else if (optBoolean("failed") && optInt("load_error_code") != 0)
                put("error_code", "AUTH-PAGE ${optInt("load_error_category")}-${optInt("load_error_code")}")
        }
    }
    override fun frame(): ByteArray = ByteArray(0)
    override fun open() { ui.post { if (!closed && !started) restart() } }
    private fun restart() {
        if (closed) return
        started = true; epoch++; http.cancel(); http = CloudCancellation(); pkce = Pkce()
        gecko?.close(); exchanging = false; status = ""; errorCode = ""
        val attempt = epoch
        val renderer = GeckoLoginSession(host) { url, main -> navigation(attempt, url, main) }
        gecko = renderer
        renderer.pause(paused); renderer.open(authorizeUrl(clientId(), pkce.challenge, pkce.state))
    }
    private fun clientId() = clientId(host()?.packageName.orEmpty())

    private fun navigation(attempt: Long, url: String, main: Boolean): String? {
        if (closed || epoch != attempt || errorCode.isNotEmpty() || exchanging) return null
        if (callback(url)) {
            // Consume the redirect before Gecko hands it to the system.
            if (main) finish(attempt, url) else errorCode = CloudLoginFailure(Stage.CALLBACK).code
            return null
        }
        if (!allowed(url, main)) {
            if (main) status = "Page unavailable. Try reloading."
            return null
        }
        if (main && status == "Page unavailable. Try reloading.") status = ""
        return url
    }
    private fun finish(attempt: Long, url: String) {
        val session = pkce
        val query = runCatching { parameters(url) }.getOrNull()
        if (query == null || query["state"] != session.state || query.containsKey("error") || query["code"].isNullOrEmpty()) {
            errorCode = CloudLoginFailure(Stage.CALLBACK).code; return
        }
        val cancellation = http
        exchanging = true; status = "Connecting…"
        gecko?.pause(true)
        val body = JSONObject().put("client_id", clientId()).put("code", query.getValue("code")).put("code_verifier", session.verifier)
        Thread({
            val result = runCatching {
                val response = exchange?.invoke(body, cancellation) ?: CloudLoginFailure.at(Stage.EXCHANGE) {
                    OpenListBackend.start(host()?.applicationContext ?: error("Activity unavailable"))
                    OpenListBackend.request("POST", "/guangya-auth", body, cancellation).getJSONObject("data")
                }
                response.optJSONObject("credential") ?: throw CloudLoginFailure(Stage.CREDENTIAL)
            }
            ui.post {
                if (closed || epoch != attempt || pkce !== session) return@post
                result.fold(onSuccess = {
                    if (!authorized(it)) { exchanging = false; errorCode = CloudLoginFailure(Stage.SAVE).code }
                }, onFailure = {
                    exchanging = false
                    errorCode = (it as? CloudLoginFailure ?: CloudLoginFailure(Stage.CREDENTIAL, it as? Exception)).code
                })
            }
        }, "GuangyaOAuth").start()
    }
    override fun action(action: String, x: Float, y: Float, text: String) {
        if (closed || paused) return
        ui.post {
            if (closed || paused) return@post
            when (action) {
                "reload" -> restart()
                // The login page has one layout; desktop/mobile switching is not offered.
                "desktop", "mobile" -> Unit
                else -> if (!exchanging && errorCode.isEmpty()) gecko?.action(action, x, y, text)
            }
        }
    }
    override fun pause(value: Boolean) { paused = value; gecko?.pause(value) }
    override fun close() {
        closed = true; http.cancel()
        ui.post { epoch++; gecko?.close(); gecko = null }
    }

    companion object {
        const val REDIRECT = "thru3d://oauth/guangyapan"
        private const val PICO_CLIENT = "av7rsoJS2g0dIaXH"
        private const val META_CLIENT = "av7r1lQqdEuV1Er3"
        /** The Meta store package has its own registered client; every other package shares one. */
        fun clientId(packageName: String) = if (packageName.startsWith("com.thru3d.quest")) META_CLIENT else PICO_CLIENT
        fun authorizeUrl(client: String, challenge: String, state: String): String {
            fun q(text: String) = URLEncoder.encode(text, "UTF-8").replace("+", "%20")
            return "https://www.guangyapan.com/oauth/?client_id=${q(client)}&response_type=code&scope=${q("user offline")}" +
                "&code_challenge=$challenge&code_challenge_method=S256&redirect_uri=${q(REDIRECT)}&state=$state"
        }
        fun callback(value: String) = value.startsWith("$REDIRECT?") || value == REDIRECT
        fun parameters(value: String): Map<String, String> {
            val query = URI(value).rawQuery ?: return emptyMap()
            return query.split('&').filter { it.isNotEmpty() }.associate {
                URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
            }
        }
        /** The page and its sign-in calls stay on GuangYaPan; verification widgets may frame other https hosts. */
        fun allowed(value: String, mainFrame: Boolean): Boolean {
            if (!mainFrame && value == "about:blank") return true
            val uri = runCatching { URI(value) }.getOrNull() ?: return false
            if (uri.scheme != "https" || uri.rawUserInfo != null || uri.port !in setOf(-1, 443)) return false
            return !mainFrame || CloudDrive.within(uri.host, "guangyapan.com")
        }
        fun addition(value: JSONObject): JSONObject {
            val client = value.optString("client_id")
            require((client == PICO_CLIENT || client == META_CLIENT) && value.optString("refresh_token").length in 1..16384)
            return JSONObject().put("root_folder_id", "").put("client_id", client).put("refresh_token", value.getString("refresh_token"))
        }
    }
}
