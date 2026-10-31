package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.CookieManager
import java.net.CookiePolicy
import java.net.HttpURLConnection
import java.net.URI

/** One login attempt's APIpage cookies stay native and never share the browser profile. */
internal class OpenListLoginExchange(private val cancellation: CloudCancellation,
    private val connect: (URI) -> HttpURLConnection = { it.toURL().openConnection() as HttpURLConnection }) {
    private val cookies = CookieManager(null, CookiePolicy.ACCEPT_ORIGINAL_SERVER)

    fun request(provider: String): String {
        val response = get(OpenListAuth.requestUrl(provider), true)
        require(response.code == 200)
        return authorizationTarget(JSONObject(response.body), provider)
    }

    fun toolCookies(): String = cookies.get(URI(OpenListAuth.ORIGIN + "/"), emptyMap())
        .filterKeys { it.equals("Cookie", true) }.values.flatten().joinToString("; ")

    /** Called only after this attempt accepts the matching state/code callback.
     * Consume the token redirect before APIpage's frontend can render/clear it. */
    fun exchange(callback: String, provider: String): String {
        require(OpenListAuth.callback(callback, provider))
        val response = get(callback, false)
        return tokenRedirect(callback, response.code, response.location)
    }

    private data class Response(val code: Int, val body: String, val location: String?)
    private fun get(value: String, readBody: Boolean): Response {
        require(OpenListAuth.atTool(value))
        val uri = URI(value)
        val connection = connect(uri)
        try {
            cancellation.attach(connection)
            connection.instanceFollowRedirects = false; connection.useCaches = false
            connection.connectTimeout = 15000; connection.readTimeout = 20000
            connection.setRequestProperty("User-Agent", CloudHttp.UA)
            connection.setRequestProperty("Accept", "application/json")
            cookies.get(uri, emptyMap()).forEach { (name, values) ->
                if (name.equals("Cookie", true)) connection.setRequestProperty(name, values.joinToString("; "))
            }
            val code = connection.responseCode
            cookies.put(uri, connection.headerFields.filterKeys { it != null })
            val body = if (readBody && code == 200) connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                try {
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        require(output.size() + count <= 90000)
                        output.write(buffer, 0, count)
                    }
                    val bytes = output.toByteArray()
                    try { String(bytes, Charsets.UTF_8) } finally { bytes.fill(0) }
                } finally { buffer.fill(0) }
            } else ""
            return Response(code, body, connection.getHeaderField("Location"))
        } finally { cancellation.detach(connection); connection.disconnect() }
    }

    companion object {
        internal fun authorizationTarget(data: JSONObject, provider: String): String {
            val target = data.getString("text")
            require(target.length <= 16384 && !OpenListAuth.atTool(target) && OpenListAuth.allowed(target, provider, true))
            if (provider == CloudDrive.QUARK) {
                val uri = URI(target)
                require(uri.host == "pan.quark.cn" && uri.path == "/open/v1/oauth/authorize")
                OpenListOAuthSession(provider).providerNavigation(target, "")
            }
            return target
        }

        internal fun tokenRedirect(callback: String, code: Int, location: String?): String {
            require(code in setOf(301, 302, 303, 307, 308) && location != null && location.length <= 90000)
            val target = URI(callback).resolve(location).toString()
            val uri = URI(target)
            require(OpenListAuth.atTool(target) && uri.path in setOf("", "/") && uri.rawQuery.isNullOrEmpty() && !uri.rawFragment.isNullOrEmpty())
            return target
        }
    }
}
