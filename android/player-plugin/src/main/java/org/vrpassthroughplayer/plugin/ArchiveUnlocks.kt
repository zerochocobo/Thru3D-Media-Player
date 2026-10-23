package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/** Exact archive associations only: never try the whole password book against a remote file. */
internal class ArchiveUnlocks(private val load: () -> JSONArray, private val save: (JSONArray) -> Unit) {
    private val memory = LinkedHashMap<String, String>()
    private fun key(uri: String) = MessageDigest.getInstance("SHA-256").digest(uri.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

    @Synchronized fun password(uri: String, book: Set<String>): String {
        val key = key(uri)
        memory[key]?.let { return it }
        val saved = load()
        for (i in 0 until saved.length()) {
            val item = saved.getJSONObject(i)
            val password = item.getString("password")
            if (item.getString("source") == key && password in book) return password
        }
        return ""
    }

    @Synchronized fun verified(uri: String, password: String, persist: Boolean) {
        if (password.isEmpty()) return
        val key = key(uri)
        memory.remove(key); memory[key] = password
        while (memory.size > 100) memory.remove(memory.keys.first())
        if (!persist) return
        val values = JSONArray().put(JSONObject().put("source", key).put("password", password))
        val old = load()
        for (i in 0 until old.length()) {
            val item = old.getJSONObject(i)
            if (item.getString("source") != key && values.length() < 100) values.put(item)
        }
        save(values)
    }

    @Synchronized fun forget(password: String) {
        memory.entries.removeAll { it.value == password }
        val values = JSONArray()
        val old = load()
        for (i in 0 until old.length()) {
            val item = old.getJSONObject(i)
            if (item.getString("password") != password) values.put(item)
        }
        if (values.length() != old.length()) save(values)
    }

    @Synchronized fun clear() { memory.clear() }
}
