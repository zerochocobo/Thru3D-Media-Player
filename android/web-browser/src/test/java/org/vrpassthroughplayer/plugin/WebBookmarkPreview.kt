package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.io.File
import java.net.InetAddress

/** Host-only preview against the production socket/API and an in-memory fixture. */
object WebBookmarkPreview {
    @JvmStatic fun main(args: Array<String>) {
        val root = File(args[0])
        val library = WebBrowserLibrary("{}") {}
        for ((url, title) in listOf("https://www.youtube.com" to "YouTube · VR180", "https://www.bilibili.com" to "哔哩哔哩", "https://vimeo.com" to "Vimeo · Films", "https://threejs.org" to "Creative worlds")) library.bookmark(url, title)
        library.recordHistory = true
        library.visit("https://video.example/watch?v=broken", "Playback sample · VR180", 1793155200000)
        library.visit("https://video.example/watch?v=second", "第二个网页 · 日本語", 1793158800000)
        library.recordHistory = false
        library.visit("https://session.example/clip", "Session-only visit", 1793162400000)
        val server = WebBookmarkShare({ path ->
            File(root, if (path == "translations.json") "app/godot/i18n/translations.json" else "android/web-browser/src/main/assets/$path").readBytes()
        }, { request, alive -> synchronized(library) { if (alive()) library.remote(request) else JSONObject().put("error", "expired") } },
            { InetAddress.getByName("127.0.0.1") }, args.getOrNull(1)?.toInt() ?: 18791)
        check(server.start(args.contains("--secure")).isEmpty())
        println(server.status())
        Runtime.getRuntime().addShutdownHook(Thread { server.close() })
        while (server.status().optBoolean("active")) Thread.sleep(250)
    }
}
