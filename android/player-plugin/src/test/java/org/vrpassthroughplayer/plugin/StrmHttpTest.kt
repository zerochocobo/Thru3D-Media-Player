package org.vrpassthroughplayer.plugin

import org.vrpassthroughplayer.plugin.CloudStreamSourceTest.HttpServer
import org.junit.Assert.*
import org.junit.Test
import java.net.InetSocketAddress

class StrmHttpTest {
    @Test fun redirectsUseTheFinalDocumentDirectoryAndNeverDownloadTheVideo() {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        var videoReads = 0
        server.createContext("/old.strm") { exchange ->
            exchange.responseHeaders.add("Location", "/index/movie.strm"); exchange.sendResponseHeaders(302, -1); exchange.close()
        }
        server.createContext("/index/movie.strm") { exchange ->
            val body = "../video.mkv?sign=a%2Fb".toByteArray()
            exchange.sendResponseHeaders(200, body.size.toLong()); exchange.responseBody.use { it.write(body) }
        }
        server.createContext("/video.mkv") { exchange -> videoReads++; exchange.sendResponseHeaders(200, -1); exchange.close() }
        server.start()
        try {
            val base = "http://127.0.0.1:${server.address.port}"
            assertEquals("$base/video.mkv?sign=a%2Fb", StrmResolver(StrmHttp::read).resolve("$base/old.strm"))
            assertEquals(0, videoReads)
        } finally { server.stop(0) }
    }
    @Test fun exposesFixedFailuresForMissingDeniedOversizedAndInvalidRedirects() {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        for (status in listOf(401, 403, 404, 410, 500)) server.createContext("/$status.strm") {
            it.sendResponseHeaders(status, -1); it.close()
        }
        server.createContext("/large.strm") { it.sendResponseHeaders(200, (StrmFile.MAX_BYTES + 1).toLong()); it.close() }
        server.createContext("/unsafe.strm") {
            it.responseHeaders.add("Location", "file:///etc/passwd"); it.sendResponseHeaders(302, -1); it.close()
        }
        server.createContext("/loop.strm") {
            it.responseHeaders.add("Location", "/loop.strm"); it.sendResponseHeaders(302, -1); it.close()
        }
        server.start()
        try {
            val base = "http://127.0.0.1:${server.address.port}"
            for ((path, code) in listOf("401" to "STRM_ACCESS_DENIED", "403" to "STRM_ACCESS_DENIED", "404" to "STRM_NOT_FOUND",
                "410" to "STRM_NOT_FOUND", "500" to "STRM_READ_FAILED", "large" to "STRM_TOO_LARGE", "unsafe" to "STRM_INVALID_ADDRESS", "loop" to "STRM_READ_FAILED"))
                assertEquals(code, assertThrows(StrmFailure::class.java) { StrmHttp.read("$base/$path.strm?secret=hidden") }.code)
        } finally { server.stop(0) }
    }
}
