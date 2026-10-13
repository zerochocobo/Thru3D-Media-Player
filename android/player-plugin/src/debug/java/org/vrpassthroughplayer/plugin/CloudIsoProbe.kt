package org.vrpassthroughplayer.plugin

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest

/** Shell-only, bounded root ISO diagnostics using the production cloud byte source.
 * No cookies, account secrets, signed download URLs or raw media enter the report. */
internal object CloudIsoProbe {
    fun request(context: Context, request: String): Int {
        Thread({
            val report = JSONObject().put("state", "running").put("samples", JSONArray())
            val output = File(context.filesDir, "diagnostics/cloud_iso_$request.json")
            output.parentFile?.mkdirs()
            fun save() = output.writeText(report.toString())
            try {
                CloudLibrary.start(context)
                val accounts = CloudAccountStore(context).load()
                val account = (0 until accounts.length()).map(accounts::getJSONObject)
                    .firstOrNull { it.optString("provider") in setOf(CloudDrive.OPEN115, CloudDrive.P115) }
                    ?: error("115 account unavailable")
                val provider = account.getString("provider")
                report.put("provider", provider).put("stage", "listing")
                save()
                val client: CloudClient = if (OpenListBackend.supported(provider)) {
                    OpenListBackend.start(context); OpenListBackend.client(account)
                } else CloudDrive(provider, account.getString("cookie"))
                val files = ArrayList<CloudFile>()
                var offset = 0
                repeat(16) {
                    if (offset >= 0 && files.size < 2) {
                        report.put("listing_offset", offset); save()
                        val page = client.page("/", offset)
                        files.addAll(page.files.filter { !it.folder && it.name.endsWith(".iso", true) })
                        offset = page.nextOffset
                    }
                }
                report.put("iso_matches", files.size)
                LocalStreamServer().use { server ->
                    for (file in files.take(2)) {
                        val item = JSONObject().put("name", file.name).put("size", file.size)
                        report.getJSONArray("samples").put(item)
                        val uri = CloudPaths.uri("/" + account.getString("id") + CloudPaths.child("/", file.name))
                        item.put("uri", uri)
                        item.put("stage", "resolve"); save()
                        // Exact production resolver, lease, proxy and original-file Range path.
                        val url = CloudLibrary.playable(uri, server)
                        try {
                            val ranges = JSONArray(); item.put("ranges", ranges)
                            for (offset in listOf(0L, 32768L, 524288L, file.size - 2048)) {
                                item.put("stage", "range").put("range_offset", offset); save()
                                val connection = URI(url).toURL().openConnection() as HttpURLConnection
                                connection.connectTimeout = 15000; connection.readTimeout = 30000
                                connection.setRequestProperty("Range", "bytes=$offset-${offset + 2047}")
                                try {
                                    val row = JSONObject().put("offset", offset).put("status", connection.responseCode)
                                    ranges.put(row)
                                    if (connection.responseCode == 206) {
                                        val bytes = connection.inputStream.use { it.readBytes() }
                                        row.put("bytes", bytes.size).put("sha256", MessageDigest.getInstance("SHA-256")
                                            .digest(bytes).joinToString("") { "%02x".format(it) })
                                        if (offset == 32768L) row.put("udf_marker", String(bytes.copyOfRange(1, 6), Charsets.US_ASCII))
                                    }
                                } finally { connection.disconnect() }
                            }
                            item.put("stage", "native_preflight")
                            save()
                            try {
                                val disc = MpvSourceNative.probeIso(url)
                                item.put("disc", JSONArray(disc.toList())).put("passed", true)
                            } catch (e: Exception) { item.put("error", e.message).put("passed", false) }
                        } finally { server.revoke(url) }
                    }
                }
                report.put("state", "complete")
            } catch (e: Exception) {
                report.put("state", "failed").put("error", e.javaClass.simpleName)
                    .put("reason", (e as? CloudFailure)?.reason)
            } finally {
                save()
            }
        }, "QuestCloudIsoProbe").start()
        return 1
    }
}
