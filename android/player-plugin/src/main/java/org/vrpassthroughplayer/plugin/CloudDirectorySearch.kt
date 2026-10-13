package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Legacy provider fallback: one directory, bounded metadata, no recursive crawl. */
internal class CloudDirectorySearch(private val now: () -> Long = { System.nanoTime() / 1_000_000 }) {
    private data class Snapshot(val account: String, val identity: String, val path: String, val query: String,
        val kind: String, val files: List<CloudFile>, val expires: Long)
    private val snapshots = LinkedHashMap<String, Snapshot>()
    @Synchronized fun search(account: String, identity: String, client: CloudClient, path: String, query: String,
        kind: String, cursor: String, refresh: Boolean): JSONObject {
        require(kind in setOf("all", "video", "image", "folder") && query.isNotBlank())
        val parts = cursor.split(':'); var key = parts.first(); var offset = 0
        val snapshot: Snapshot
        if (cursor.isEmpty()) {
            snapshots.entries.removeAll { it.value.expires <= now() }
            while (snapshots.size >= 4) snapshots.remove(snapshots.keys.first())
            val files = ArrayList<CloudFile>(); val seen = HashSet<String>(); var next = 0
            while (true) {
                if (Thread.currentThread().isInterrupted) throw CloudFailure()
                val page = client.page(path, next, refresh && next == 0)
                require(page.total <= 20_000 && files.size + page.files.size <= 20_000) { "Folder too large to search" }
                page.files.forEach { require(seen.add(it.objectId)) }
                files.addAll(page.files)
                if (page.nextOffset < 0) break
                require(page.nextOffset > next); next = page.nextOffset
            }
            val matches = files.filter { it.name.contains(query, ignoreCase = true) &&
                if (it.folder) kind in setOf("all", "folder") else MediaKinds.supportedFileName(it.name) && (kind == "all" || MediaKinds.fileNameKind(it.name) == kind) }
                .sortedWith(CloudSortedPages.comparator("name_asc"))
            snapshot = Snapshot(account, identity, path, query, kind, matches, now() + 300_000)
            key = UUID.randomUUID().toString(); snapshots[key] = snapshot
        } else {
            require(parts.size == 2 && !refresh) { "Search expired. Search again" }
            offset = parts[1].toIntOrNull() ?: error("Search expired. Search again")
            snapshot = snapshots[key] ?: error("Search expired. Search again")
            require(snapshot.account == account && snapshot.identity == identity && snapshot.path == path &&
                snapshot.query == query && snapshot.kind == kind && snapshot.expires > now()) { "Search expired. Search again" }
        }
        require(offset >= 0 && offset % 48 == 0 && offset <= snapshot.files.size)
        val end = minOf(offset + 48, snapshot.files.size); val content = JSONArray()
        for (i in offset until end) {
            val file = snapshot.files[i]
            content.put(JSONObject().put("name", file.name).put("is_dir", file.folder).put("size", file.size)
                .put("path", CloudPaths.child(path, file.name)).put("token", "$key:$i"))
        }
        return JSONObject().put("content", content).put("next_cursor", if (end < snapshot.files.size) "$key:$end" else "").put("limited", false)
    }
    @Synchronized fun resolve(account: String, identity: String, token: String): JSONObject {
        val parts = token.split(':'); require(parts.size == 2)
        val snapshot = snapshots[parts[0]] ?: error("Search expired. Search again")
        require(snapshot.account == account && snapshot.identity == identity && snapshot.expires > now()) { "Search expired. Search again" }
        val index = parts[1].toIntOrNull() ?: error("Invalid search result")
        val file = snapshot.files.getOrNull(index) ?: error("Invalid search result")
        return JSONObject().put("name", file.name).put("path", CloudPaths.child(snapshot.path, file.name)).put("is_dir", file.folder)
    }
}
