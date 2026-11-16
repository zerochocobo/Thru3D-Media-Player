package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLDecoder

/** A playlist is a browsing context, never a content identity of its own. */
object WebBrowserBilibiliPage {
    data class Page(val id: String, val part: Int, val playlist: Boolean = false)
    fun parse(value: String): Page? = runCatching {
        val uri = URI(value)
        require(uri.scheme == "https" && uri.host == "www.bilibili.com" && uri.port == -1 && uri.rawUserInfo == null)
        val pairs = uri.rawQuery.orEmpty().split('&').filter { it.isNotEmpty() }.map {
            URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('=', ""), "UTF-8")
        }
        for (key in listOf("bvid", "oid", "p")) require(pairs.count { it.first == key } <= 1)
        val query = pairs.toMap()
        val pgc = Regex("/bangumi/play/((?:ep|ss)[1-9][0-9]{0,19})/?").matchEntire(uri.path)?.groupValues?.get(1)
        if (pgc != null) return Page(pgc, 1)
        val playlist = Regex("/(?:list/(?:watchlater|ml[1-9][0-9]{0,19}|[1-9][0-9]{0,19})|medialist/play/[1-9][0-9]{0,19})/?").matches(uri.path)
        if (playlist && query.containsKey("oid")) require(query.getValue("oid").matches(Regex("[1-9][0-9]{0,19}")))
        val id = Regex("/video/(BV[A-Za-z0-9]{10}|av[0-9]+)/?").matchEntire(uri.path)?.groupValues?.get(1)
            ?: if (playlist) {
                query["bvid"]?.also { require(it.matches(Regex("BV[A-Za-z0-9]{10}"))) }
                    ?: query["oid"]?.also { require(it.matches(Regex("[1-9][0-9]{0,19}"))) }?.let { "av$it" }.orEmpty()
            } else return null
        val part = if (query.containsKey("p")) query.getValue("p").toInt() else 1
        require(part in 1..10000)
        Page(id, part, playlist)
    }.getOrNull()
}
