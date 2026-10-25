package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** Durable object identity only. Never persist a resolved URL, token or driver object. */
internal object PdfSourceIdentity {
    fun selected(uri: String, remote: String, value: JSONObject): CloudFile? {
        if (!uri.startsWith("cloud://") || value.optString("uri") != uri) return null
        val id = value.optString("id")
        val size = value.optLong("size", 0)
        if (id.isBlank() || id.length > 2048 || id.any { it.isISOControl() } || id.contains("://") || size <= 0) return null
        return CloudFile(remote.substringAfterLast('/'), false, size, remote,
            objectId = id, modified = value.optLong("modified", -1))
    }

    fun from(uri: String, file: CloudFile) = JSONObject().put("uri", uri).put("id", file.objectId)
        .put("size", file.size).put("modified", file.modified)
}
