package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import org.vrpassthroughplayer.plugin.CloudLoginFailure.Stage

/** Dedicated login renderer; provider state/nonce/appId checks stay in OpenListOAuthSession. */
internal class CloudWebLogin(private val host: () -> Activity?, private val provider: String,
    private val authorized: (OpenListAuth.Credential) -> Boolean) : AccountWebLogin {
    private val ui = Handler(Looper.getMainLooper())
    @Volatile private var closed = false
    @Volatile private var paused = false
    @Volatile private var status = "Loading…"
    @Volatile private var errorCode = ""
    @Volatile private var gecko: GeckoLoginSession? = null
    private var flow = OpenListOAuthSession(provider)
    private var epoch = 0L
    private var exchanging = false
    private var started = false
    private var desktop = provider == CloudDrive.BAIDU
    private var http = CloudCancellation()
    private var exchange = OpenListLoginExchange(http)

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
        started = true; epoch++; http.cancel(); http = CloudCancellation(); exchange = OpenListLoginExchange(http)
        gecko?.close(); flow = OpenListOAuthSession(provider); exchanging = false; status = "Loading…"; errorCode = ""
        val attempt = epoch
        val connection = exchange
        val renderer = GeckoLoginSession(host, desktopOnly = provider == CloudDrive.BAIDU,
            touchOnly = provider == CloudDrive.ONEDRIVE, initialDesktop = desktop) { url, main -> navigation(attempt, url, main) }
        gecko = renderer
        Thread({
            val target = runCatching { connection.request(provider) }
            ui.post {
                if (closed || epoch != attempt) return@post
                try {
                    val prepared = flow.providerNavigation(target.getOrThrow(), connection.toolCookies())
                    status = ""; renderer.pause(paused); renderer.open(prepared)
                } catch (error: Exception) { fail(CloudLoginFailure(Stage.REQUEST, error)) }
            }
        }, "CloudLoginRequest").start()
    }
    private fun fail(error: CloudLoginFailure) { errorCode = error.code }

    private fun navigation(attempt: Long, url: String, main: Boolean): String? {
        if (closed || epoch != attempt || errorCode.isNotEmpty() || exchanging) return null
        if (!CloudWebNavigation.allowed(url, provider, main)) {
            if (main) { status = "Page unavailable. Try reloading." }
            return null
        }
        try {
            if (OpenListAuth.callback(url, provider)) {
                if (!flow.matchesCallback(url) && !flow.allowCallback(url)) {
                    fail(CloudLoginFailure(Stage.CALLBACK)); return null
                }
                exchange(attempt, url)
                // Consume the final callback before it can render token fields.
                return null
            }
            // APIpage is native-only: never render its request/result fields.
            if (OpenListAuth.atTool(url)) return null
            val next = if (main || OpenListAuth.quarkBrokerCallback(url)) flow.providerNavigation(url, "") else url
            if (main && status == "Page unavailable. Try reloading.") status = ""
            return next
        } catch (error: Exception) { fail(CloudLoginFailure(Stage.CALLBACK, error)); return null }
    }
    private fun exchange(attempt: Long, callback: String) {
        val session = flow
        val connection = exchange
        val cancellation = http
        if (exchanging) return
        exchanging = true; status = "Connecting…"
        gecko?.pause(true)
        Thread({
            val result = runCatching {
                val credential = if (provider == CloudDrive.QUARK) {
                    val nonce = session.quarkNonce ?: throw CloudLoginFailure(Stage.CALLBACK)
                    val response = CloudLoginFailure.at(Stage.EXCHANGE) { OpenListQuarkExchange.exchange(nonce, cancellation) }
                    session.quarkCredential(response)
                } else {
                    val response = CloudLoginFailure.at(Stage.EXCHANGE) { connection.exchange(callback, provider) }
                    session.credential(response)
                }
                credential ?: throw CloudLoginFailure(Stage.CREDENTIAL)
            }
            ui.post {
                if (closed || epoch != attempt || flow !== session) return@post
                result.fold(onSuccess = {
                    if (!authorized(it)) { exchanging = false; fail(CloudLoginFailure(Stage.SAVE)) }
                }, onFailure = {
                    exchanging = false
                    fail(it as? CloudLoginFailure ?: CloudLoginFailure(Stage.CREDENTIAL, it as? Exception))
                })
            }
        }, "CloudPublicOAuth").start()
    }
    override fun action(action: String, x: Float, y: Float, text: String) {
        if (closed || paused) return
        ui.post {
            if (closed || paused) return@post
            when (action) {
                "reload" -> restart()
                "desktop", "mobile" -> if (!exchanging && errorCode.isEmpty() && provider != CloudDrive.BAIDU && desktop != (action == "desktop")) {
                    desktop = action == "desktop"
                    // Start at the authorization entry with the new UA/viewport already set;
                    // reloading a mobile redirect can keep a provider on its mobile endpoint.
                    restart()
                }
                else -> if (!exchanging && errorCode.isEmpty()) gecko?.action(action, x, y, text)
            }
        }
    }
    override fun pause(value: Boolean) { paused = value; gecko?.pause(value) }
    override fun close() {
        closed = true; http.cancel()
        ui.post { epoch++; gecko?.close(); gecko = null }
    }

}
