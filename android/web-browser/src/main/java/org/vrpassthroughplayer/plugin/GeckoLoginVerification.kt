package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.mozilla.geckoview.GeckoRuntime
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.WebExtension

/** The official Thunder review page expects this native bridge. Only the
 * explicitly bound login session receives the transient challenge. */
class GeckoLoginVerification(private val review: JSONObject, private val result: (JSONObject) -> Unit) {
    private var closed = false
    private var port: WebExtension.Port? = null
    fun attach(runtime: GeckoRuntime, session: GeckoSession, ready: (Boolean) -> Unit) {
        runtime.webExtensionController.ensureBuiltIn("resource://android/assets/thunder-login/", ID).accept({ extension ->
            if (closed) return@accept
            if (extension == null) { ready(false); return@accept }
            session.webExtensionController.setMessageDelegate(extension, object : WebExtension.MessageDelegate {
                override fun onConnect(incoming: WebExtension.Port) {
                    if (closed || incoming.sender.session !== session || !incoming.sender.isTopLevel ||
                        incoming.sender.webExtension.id != ID || incoming.sender.url != PAGE) { incoming.disconnect(); return }
                    port?.disconnect(); port = incoming
                    incoming.setDelegate(object : WebExtension.PortDelegate {
                        override fun onPortMessage(message: Any, active: WebExtension.Port) {
                            if (closed || active !== port) return
                            val data = message as? JSONObject ?: return
                            when (data.optString("type")) {
                                "ready" -> active.postMessage(JSONObject().put("type", "review").put("review", review))
                                "verified" -> {
                                    val key = data.optString("credit_key")
                                    if (key.length !in 1..8192) return
                                    closed = true
                                    result(JSONObject().put("credit_key", key))
                                    active.disconnect(); port = null
                                }
                            }
                        }
                        override fun onDisconnect(active: WebExtension.Port) { if (port === active) port = null }
                    })
                }
            }, "thunder_login")
            ready(true)
        }, { ready(false) })
    }
    fun close() { closed = true; port?.disconnect(); port = null }
    companion object {
        private const val ID = "thunder-login@thru3d.local"
        private const val PAGE = "https://i.xunlei.com/xlcaptcha/android.html"
    }
}
