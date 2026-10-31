package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.os.Handler
import android.os.Looper
import org.json.JSONObject

/** Shared isolated login renderer; provider state/nonce/appId checks stay in OpenListOAuthSession. */
internal class CloudWebLogin(private val host: () -> Activity?, private val provider: String,
    private val authorized: (OpenListAuth.Credential) -> Boolean) : AccountWebLogin {
    private val ui = Handler(Looper.getMainLooper())
    @Volatile private var closed = false
    @Volatile private var paused = false
    @Volatile private var status = "Loading…"
    @Volatile private var failed = false
    @Volatile private var gecko: GeckoLoginSession? = null
    private var flow = OpenListOAuthSession(provider)
    private var epoch = 0L
    private var exchanging = false
    private var started = false
    private var http = CloudCancellation()
    private var exchange = OpenListLoginExchange(http)

    override fun snapshot(): JSONObject = (gecko?.snapshot() ?: JSONObject().put("renderer", "gecko"))
        .put("status", status).apply { if (failed) put("failed", true) }
    override fun frame(): ByteArray = ByteArray(0)
    override fun open() { ui.post { if (!closed && !started) restart() } }
    private fun restart() {
        if (closed) return
        started = true; epoch++; http.cancel(); http = CloudCancellation(); exchange = OpenListLoginExchange(http)
        gecko?.close(); flow = OpenListOAuthSession(provider); exchanging = false; failed = false; status = "Loading…"
        val attempt = epoch
        val connection = exchange
        val renderer = GeckoLoginSession(host, desktopOnly = provider == CloudDrive.BAIDU,
            touchOnly = provider == CloudDrive.ONEDRIVE) { url, main -> navigation(attempt, url, main) }
        gecko = renderer
        Thread({
            val target = runCatching { connection.request(provider) }.getOrNull()
            ui.post {
                if (closed || epoch != attempt) return@post
                if (target == null) { fail(); return@post }
                try {
                    val prepared = flow.providerNavigation(target, connection.toolCookies())
                    status = ""; renderer.pause(paused); renderer.open(prepared)
                } catch (_: Exception) { fail() }
            }
        }, "CloudLoginRequest").start()
    }
    private fun fail() { failed = true; status = "Authorization failed. Try again." }

    private fun navigation(attempt: Long, url: String, main: Boolean): String? {
        if (closed || epoch != attempt || failed || exchanging) return null
        if (!CloudWebNavigation.allowed(url, provider, main)) {
            if (main) { status = "Page unavailable. Try reloading." }
            return null
        }
        try {
            if (OpenListAuth.callback(url, provider)) {
                if (!flow.matchesCallback(url) && !flow.allowCallback(url)) { fail(); return null }
                exchange(attempt, url)
                // Consume the final callback before it can render token fields.
                return null
            }
            // APIpage is native-only: never render its request/result fields.
            if (OpenListAuth.atTool(url)) return null
            val next = if (main || OpenListAuth.quarkBrokerCallback(url)) flow.providerNavigation(url, "") else url
            if (main && status == "Page unavailable. Try reloading.") status = ""
            return next
        } catch (_: Exception) { fail(); return null }
    }
    private fun exchange(attempt: Long, callback: String) {
        val session = flow
        val connection = exchange
        if (exchanging) return
        exchanging = true; status = "Connecting…"
        gecko?.pause(true)
        Thread({
            val result = runCatching {
                if (provider == CloudDrive.QUARK) session.quarkCredential(OpenListQuarkExchange.exchange(session.quarkNonce ?: error("Missing nonce")))
                else session.credential(connection.exchange(callback, provider))
            }.getOrNull()
            ui.post {
                if (closed || epoch != attempt || flow !== session) return@post
                if (result == null || !authorized(result)) { exchanging = false; fail() }
            }
        }, "CloudPublicOAuth").start()
    }
    override fun action(action: String, x: Float, y: Float, text: String) {
        if (closed || paused) return
        ui.post {
            if (closed || paused) return@post
            when (action) {
                "reload" -> restart()
                else -> if (!exchanging && !failed) gecko?.action(action, x, y, text)
            }
        }
    }
    override fun pause(value: Boolean) { paused = value; gecko?.pause(value) }
    override fun close() {
        closed = true; http.cancel()
        ui.post { epoch++; gecko?.close(); gecko = null }
    }

}
