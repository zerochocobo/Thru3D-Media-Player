package org.vrpassthroughplayer.plugin

import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import org.mozilla.geckoview.WebExtension
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** Credentials travel only between the privileged extension and a waiting extractor worker. */
internal class WebBrowserCookies {
    private val ui = Handler(Looper.getMainLooper())
    private var port: WebExtension.Port? = null
    private val waiting = mutableMapOf<String, CompletableFuture<JSONArray>>()
    @Volatile private var ready = CompletableFuture<Unit>()
    fun isReady(): Boolean = ready.isDone && !ready.isCompletedExceptionally

    fun bind(extension: WebExtension) {
        extension.setMessageDelegate(object : WebExtension.MessageDelegate {
            override fun onConnect(connection: WebExtension.Port) {
                val sender = connection.sender
                if (sender.webExtension.id != "web-video@thru3d.local" || sender.session != null ||
                    sender.environmentType != WebExtension.MessageSender.ENV_TYPE_EXTENSION) {
                    connection.disconnect(); return
                }
                port?.disconnect()
                port = connection
                ready.complete(Unit)
                connection.setDelegate(object : WebExtension.PortDelegate {
                    override fun onPortMessage(message: Any, port: WebExtension.Port) {
                        if (port !== this@WebBrowserCookies.port) return
                        val data = message as? JSONObject ?: return
                        val future = waiting.remove(data.optString("request")) ?: return
                        val cookies = data.optJSONArray("cookies")
                        if (!data.optBoolean("ok") || cookies == null || cookies.length() > 256 ||
                            cookies.toString().length > 256 * 1024) future.completeExceptionally(IllegalStateException("Browser session unavailable"))
                        else future.complete(cookies)
                    }
                    override fun onDisconnect(port: WebExtension.Port) {
                        if (port !== this@WebBrowserCookies.port) return
                        this@WebBrowserCookies.port = null
                        ready = CompletableFuture()
                        failPending()
                    }
                })
            }
        }, "thru3d_cookies")
    }

    /** Worker-only, bounded, never writes a Cookie file or publishes credentials in browser state. */
    fun snapshot(url: String): JSONArray {
        check(Looper.myLooper() != Looper.getMainLooper())
        val domains = WebVideoSessionScope.domains(url)
        if (domains.isEmpty()) return JSONArray()
        // A cold URL-only handoff must wait for the persisted Gecko profile to open,
        // rather than silently extracting anonymously before the extension connects.
        ready.get(10, TimeUnit.SECONDS)
        val request = UUID.randomUUID().toString()
        val result = CompletableFuture<JSONArray>()
        ui.post {
            if (result.isDone) return@post
            val current = port
            if (current == null) result.completeExceptionally(IllegalStateException("Browser session unavailable"))
            else {
                waiting[request] = result
                try { current.postMessage(JSONObject().put("request", request).put("domains", JSONArray(domains))) }
                catch (_: Exception) { waiting.remove(request); result.completeExceptionally(IllegalStateException("Browser session unavailable")) }
            }
        }
        try { return result.get(5, TimeUnit.SECONDS) }
        finally { result.cancel(false); ui.post { waiting.remove(request) } }
    }

    private fun failPending() {
        waiting.values.forEach { it.completeExceptionally(IllegalStateException("Browser session unavailable")) }
        waiting.clear()
    }
    fun close() {
        ready.completeExceptionally(IllegalStateException("Browser session closed"))
        failPending(); port?.disconnect(); port = null
    }
}
