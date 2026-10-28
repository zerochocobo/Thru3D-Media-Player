package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject

/** Persistent history and transient visits stay separate: changing privacy never promotes old visits. */
internal class WebBrowserLibrary(saved: String,
    /** Visits arrive on every page load; they may be written off the UI thread. */
    private val saveLater: ((String) -> Unit)? = null, private val save: (String) -> Unit) {
    data class Entry(val url: String, val title: String, val at: Long) {
        fun json(): JSONObject = JSONObject().put("url", url).put("title", title).put("at", at)
    }
    private val bookmarks = mutableListOf<Entry>()
    private val history = mutableListOf<Entry>()
    private val session = mutableListOf<Entry>()
    var recordHistory = false
    init {
        val json = runCatching { JSONObject(saved) }.getOrNull()
        read(json?.optJSONArray("bookmarks"), bookmarks, 1000)
        read(json?.optJSONArray("history"), history, 200)
    }
    private fun read(items: JSONArray?, target: MutableList<Entry>, limit: Int) {
        for (i in 0 until minOf(items?.length() ?: 0, limit)) {
            val item = items?.optJSONObject(i) ?: continue
            val url = WebBrowserAddress.recordable(item.optString("url")) ?: continue
            if (target.any { it.url == url }) continue
            target.add(Entry(url, item.optString("title").take(512), item.optLong("at", 0).coerceAtLeast(0)))
        }
    }
    fun visit(url: String, title: String, at: Long) {
        val clean = WebBrowserAddress.recordable(url) ?: return
        val entry = Entry(clean, title.take(512), at)
        prepend(session, entry, 200)
        if (recordHistory) { prepend(history, entry, 200); (saveLater ?: save)(document()) }
    }
    fun bookmark(url: String, title: String): Boolean {
        val clean = WebBrowserAddress.recordable(url) ?: return false
        val existing = bookmarks.indexOfFirst { it.url == clean }
        if (existing >= 0) bookmarks.removeAt(existing)
        else { if (bookmarks.size >= 1000) return false; prepend(bookmarks, Entry(clean, title.take(512), System.currentTimeMillis()), 1000) }
        persist(); return true
    }
    fun clearHistory() { session.clear(); history.clear(); persist() }
    /** All management writes commit atomically; failed disk writes leave the visible lists intact. */
    fun edit(request: JSONObject): String {
        val oldBookmarks = bookmarks.toList()
        val oldHistory = history.toList()
        val oldSession = session.toList()
        try {
            when (request.optString("action")) {
                "import_bookmarks" -> {
                    val items = request.optJSONArray("items") ?: return "invalid_request"
                    if (items.length() !in 1..1000) return "invalid_request"
                    val additions = mutableListOf<Entry>()
                    val known = bookmarks.map { it.url }.toMutableSet()
                    for (i in 0 until items.length()) {
                        val item = items.optJSONObject(i) ?: return "invalid_request"
                        val url = WebBrowserAddress.recordable(item.optString("url")) ?: return "invalid_address"
                        if (known.add(url)) additions.add(Entry(url, item.optString("title").trim().take(512).ifEmpty { url }, System.currentTimeMillis()))
                    }
                    if (bookmarks.size + additions.size > 1000) return "bookmark_limit"
                    bookmarks.addAll(0, additions)
                }
                "save_bookmark" -> {
                    val url = WebBrowserAddress.recordable(request.optString("url")) ?: return "invalid_address"
                    val previous = request.optString("previous")
                    val index = bookmarks.indexOfFirst { it.url == previous }
                    if (previous.isNotEmpty() && index < 0) return "bookmark_missing"
                    if (bookmarks.any { it.url == url && it.url != previous }) return "bookmark_exists"
                    if (index < 0 && bookmarks.size >= 1000) return "bookmark_limit"
                    val title = request.optString("title").trim().take(512).ifEmpty { url }
                    val entry = Entry(url, title, if (index >= 0) bookmarks[index].at else System.currentTimeMillis())
                    if (index >= 0) bookmarks[index] = entry else bookmarks.add(0, entry)
                }
                "remove" -> {
                    val collection = request.optString("collection")
                    if (collection !in setOf("bookmarks", "history")) return "invalid_request"
                    val items = request.optJSONArray("urls") ?: return "invalid_request"
                    if (items.length() !in 1..1000) return "invalid_request"
                    val urls = (0 until items.length()).map { items.getString(it) }.toSet()
                    if (collection == "bookmarks") bookmarks.removeAll { it.url in urls }
                    else { history.removeAll { it.url in urls }; session.removeAll { it.url in urls } }
                }
                "clear_history" -> { history.clear(); session.clear() }
                else -> return "invalid_request"
            }
            persist()
            return ""
        } catch (error: Exception) {
            bookmarks.clear(); bookmarks.addAll(oldBookmarks)
            history.clear(); history.addAll(oldHistory)
            session.clear(); session.addAll(oldSession)
            throw error
        }
    }
    fun snapshot(): JSONObject = JSONObject().put("bookmarks", array(bookmarks))
        .put("history", array(visibleHistory()))
    private fun visibleHistory(): List<Entry> = (session + history).distinctBy { it.url }.take(200)
    private fun revision(items: JSONArray): String = java.security.MessageDigest.getInstance("SHA-256")
        .digest(items.toString().toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 255) }
    /** Explicit LAN management shares the same visible library; reading never persists transient visits. */
    fun remoteSnapshot(): JSONObject {
        val items = array(bookmarks)
        val visits = array(visibleHistory())
        return JSONObject().put("bookmarks", items).put("revision", revision(items))
            .put("history", visits).put("history_revision", revision(visits))
    }
    fun remote(request: JSONObject): JSONObject {
        val action = request.optString("action")
        if (action == "list") return remoteSnapshot()
        if (action !in setOf("save_bookmark", "import_bookmarks", "remove", "clear_history") ||
            (action == "remove" && request.optString("collection") !in setOf("bookmarks", "history")))
            return JSONObject().put("error", "invalid_request")
        val isHistory = action == "clear_history" || (action == "remove" && request.optString("collection") == "history")
        val key = if (isHistory) "history_revision" else "revision"
        if (request.optString(key) != remoteSnapshot().getString(key))
            return JSONObject().put("error", if (isHistory) "history_conflict" else "conflict")
        val error = edit(request)
        return if (error.isEmpty()) remoteSnapshot() else JSONObject().put("error", error)
    }
    private fun prepend(target: MutableList<Entry>, entry: Entry, limit: Int) {
        target.removeAll { it.url == entry.url }; target.add(0, entry)
        while (target.size > limit) target.removeAt(target.lastIndex)
    }
    private fun array(items: List<Entry>): JSONArray = JSONArray().also { a -> items.forEach { a.put(it.json()) } }
    private fun document() = JSONObject().put("version", 1).put("bookmarks", array(bookmarks)).put("history", array(history)).toString()
    private fun persist() { save(document()) }
}
