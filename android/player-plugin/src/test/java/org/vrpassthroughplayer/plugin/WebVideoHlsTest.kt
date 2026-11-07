package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Fixture
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply

class WebVideoHlsTest {
    @Test fun servesExplicitLocalByteRangesOverOneObservedGetThatIgnoresUpstreamRange() {
        val received=java.util.concurrent.atomic.AtomicInteger();val exact="/current.ts?signature=EXACT&start=4&end=12"
        Fixture { request,headers,_ ->
            assertEquals(exact,request.split(' ')[1]);assertNull(headers["range"])
            assertEquals("this-request=only",headers["cookie"]);received.incrementAndGet()
            Reply(200,body="456789ab".toByteArray())
        }.use { origin -> LocalStreamServer().use { local -> WebVideoHls(local).use { hls ->
            val upstream=origin.url+exact
            val body="#EXTM3U\n#EXT-X-VERSION:4\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\n#EXT-X-BYTERANGE:3@1\n$upstream\n#EXTINF:2,\n#EXT-X-BYTERANGE:4@4\n$upstream\n#EXT-X-ENDLIST\n"
            val input=WebVideoTrack("observed",URI(origin.url+"/list.m3u8"),emptyMap(),"mp4","avc1","mp4a",1280,544,24.0,
                transport="hls",browserManifest=body,browserHeaders=WebVideoRequestHeaders(mapOf(upstream to mapOf("cookie" to "this-request=only")),org.json.JSONArray()))
            val url=hls.prepare(input);val text=read(url).toString(Charsets.UTF_8)
            val resources=text.lines().filter { it.startsWith("http") }
            for((i,range) in listOf("bytes=1-3","bytes=4-7").withIndex()) {
                val connection=java.net.URL(resources[i]).openConnection() as java.net.HttpURLConnection
                connection.setRequestProperty("Range",range)
                try { assertEquals(206,connection.responseCode);assertEquals(if(i==0)"567" else "89ab",connection.inputStream.use { it.readBytes() }.toString(Charsets.UTF_8)) }
                finally { connection.disconnect() }
            }
            assertEquals(1,received.get());hls.close();assertFalse(local.hasSource(url));resources.forEach { assertFalse(local.hasSource(it)) }
        } } }
    }
    private fun clearInit(protected: Boolean=false,width: Int=1920): ByteArray {
        fun box(type: String,data: ByteArray) = java.nio.ByteBuffer.allocate(8+data.size).putInt(8+data.size).put(type.toByteArray()).put(data).array()
        fun trak(video: Boolean): ByteArray {
            val sample=if(video) ByteArray(78).also { java.nio.ByteBuffer.wrap(it).putShort(24,width.toShort()).putShort(26,1080.toShort()) }+box("avcC",byteArrayOf(1,100,0,40)) else ByteArray(28)
            val type=if(video) if(protected) "encv" else "avc1" else "mp4a"
            val stsd=box("stsd",java.nio.ByteBuffer.allocate(8).putInt(0).putInt(1).array()+box(type,sample))
            val mdhd=java.nio.ByteBuffer.allocate(24).putInt(12,1000).putInt(16,1000).array()
            val hdlr=ByteArray(24).also { (if(video) "vide" else "soun").toByteArray().copyInto(it,8) }
            return box("trak",box("mdia",box("mdhd",mdhd)+box("hdlr",hdlr)+box("minf",box("stbl",stsd))))
        }
        return box("ftyp","isom0000isom".toByteArray())+box("moov",trak(true)+trak(false))
    }
    @Test fun publishesObservedInlineMangoInitOnlyThroughARevocableLocalMap() {
        val init=clearInit();val encoded=java.util.Base64.getEncoder().encodeToString(init)
        Fixture { _, _, _ -> Reply(200,body=("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n"+
            "#EXT-MGTV-X-MAP:URI=\"data:video/mp4;base64,$encoded\"\n#EXTINF:1,\nsegment.m4s\n#EXT-X-ENDLIST\n").toByteArray()) }.use { origin ->
            LocalStreamServer().use { local ->
                val hls=WebVideoHls(local);val url=hls.prepare(track(origin.url+"/list"));val text=read(url).toString(Charsets.UTF_8)
                assertFalse(text.contains("data:"));assertFalse(text.contains(encoded))
                val reference=Regex("#EXT-MGTV-X-MAP:URI=\"([^\"]+)\"").find(text)!!.groupValues[1]
                assertArrayEquals(init,read(reference));hls.close();assertFalse(local.hasSource(reference));assertFalse(local.hasSource(url))
            }
        }
    }
    @Test fun refusesInvalidProtectedOversizedOrMismatchedInlineMangoInit() {
        fun data(bytes: ByteArray)="data:video/mp4;base64,"+java.util.Base64.getEncoder().encodeToString(bytes)
        val cases=listOf("data:video/mp4;base64,!!invalid",data(byteArrayOf(1,2,3)),data(clearInit(true)),data(clearInit(width=1280)),
            data(ByteArray(256*1024+1)),data(clearInit()).replace("video/mp4","text/html"))
        for(value in cases) {
            Fixture { _, _, _ -> Reply(200,body=("#EXTM3U\n#EXT-MGTV-X-MAP:URI=\"$value\"\n#EXTINF:1,\nsegment.m4s\n#EXT-X-ENDLIST\n").toByteArray()) }.use { origin ->
                LocalStreamServer().use { local -> WebVideoHls(local).use { hls ->
                    assertThrows(Exception::class.java) { hls.prepare(track(origin.url+"/list")) }
                } }
            }
        }
    }

    @Test fun rewritesObservedMangoMapReferencesAndRevokesTheirCapabilities() {
        val init=byteArrayOf(1,3,5,7)
        Fixture { _, headers, _ ->
            assertNull(headers["cookie"]);assertNull(headers["authorization"])
            Reply(200,body=init)
        }.use { cdn -> Fixture { request, _, _ ->
            when {
                request.contains("/list") -> Reply(200,body=("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4?private=one\"\n"+
                    "#EXT-MGTV-X-MAP:URI=\"${cdn.url}/alternate.mp4?private=two\"\n#EXTINF:1,\nsegment.m4s\n#EXT-X-ENDLIST\n").toByteArray())
                else -> Reply(200,body=init)
            }
        }.use { origin -> LocalStreamServer().use { local ->
            val hls=WebVideoHls(local)
            val url=hls.prepare(track(origin.url+"/list",mapOf("Cookie" to "own=only","Authorization" to "own-only")))
            val manifest=read(url).toString(Charsets.UTF_8)
            assertTrue(manifest.contains("#EXT-MGTV-X-MAP:URI=\"http://127.0.0.1:"))
            assertFalse(manifest.contains("private="));assertFalse(manifest.contains(cdn.url));assertFalse(manifest.contains(origin.url))
            val references=Regex("URI=\"([^\"]+)\"").findAll(manifest).map { it.groupValues[1] }.toList()+manifest.lines().filter { it.startsWith("http") }
            assertEquals(3,references.size);references.forEach { assertArrayEquals(init,read(it)) }
            hls.close();(references+url).forEach { assertFalse(local.hasSource(it)) }
        } } }
    }

    @Test fun mangoMapSupportKeepsUnknownAndNonHttpReferencesRejected() {
        for(tag in listOf("#EXT-MGTV-X-MAP:URI=\"file:///private\"","#EXT-UNKNOWN:URI=\"https://example.test/unhandled\"")) {
            Fixture { _, _, _ -> Reply(200,body=("#EXTM3U\n$tag\n#EXTINF:1,\nsegment.m4s\n#EXT-X-ENDLIST\n").toByteArray()) }.use { origin ->
                LocalStreamServer().use { local -> WebVideoHls(local).use { hls ->
                    assertThrows(Exception::class.java) { hls.prepare(track(origin.url+"/list")) }
                } }
            }
        }
    }

    @Test fun observedInlineBodyKeepsItsTimelineWithoutFetchingAnotherAdDecision() {
        val requests = ArrayList<String>()
        Fixture { request, headers, _ ->
            val path = request.split(' ')[1]
            synchronized(requests) { requests.add(path) }
            assertFalse("The root must come from the observed response", path.contains("playlist"))
            if (path == "/first.ts") { assertEquals("first=only",headers["cookie"]);assertNull(headers["authorization"]) }
            else { assertNull(headers["cookie"]);assertNull(headers["authorization"]) }
            Reply(200,body=byteArrayOf(1,2,3,4))
        }.use { origin -> LocalStreamServer().use { local ->
            val headers = WebVideoRequestHeaders(mapOf(origin.url+"/first.ts" to mapOf("cookie" to "first=only")),org.json.JSONArray())
            val body = "#EXTM3U\n#EXT-X-TARGETDURATION:30\n#EXTINF:30,\nfirst.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:10,\nsecond.ts\n#EXT-X-ENDLIST\n"
            val input = WebVideoTrack("observed",URI(origin.url+"/playlist.m3u8"),mapOf("cookie" to "api=must-not-spread"),
                "mp4","avc1","mp4a",1280,720,24.0,transport="hls",browserHeaders=headers,browserManifest=body)
            val hls = WebVideoHls(local)
            val url = hls.prepare(input)
            val text = read(url).toString(Charsets.UTF_8)
            assertTrue(text.contains("#EXTINF:30,"));assertTrue(text.contains("#EXT-X-DISCONTINUITY"));assertTrue(text.contains("#EXTINF:10,"))
            val resources = text.lines().filter { it.startsWith("http") }
            assertEquals(2,resources.size);resources.forEach { assertArrayEquals(byteArrayOf(1,2,3,4),read(it)) }
            hls.close();assertFalse(local.hasSource(url));resources.forEach { assertFalse(local.hasSource(it)) }
            assertEquals(listOf("/first.ts","/second.ts"),requests)
        } }
    }
    private fun track(url: String, headers: Map<String, String> = emptyMap()) = WebVideoTrack("hls", URI(url), headers,
        "mp4", "avc1.640028", "mp4a.40.2", 1920, 1080, 30.0, transport = "hls")
    private fun read(url: String) = URI(url).toURL().openStream().use { it.readBytes() }

    @Test fun ffmpegDecodesAndSeeksThroughTheProductionManifestTransport() {
        val ffmpeg = System.getenv("WEB_VIDEO_FFMPEG")
        org.junit.Assume.assumeTrue("Optional host FFmpeg integration", !ffmpeg.isNullOrEmpty())
        val root = java.io.File(System.getenv("WEB_VIDEO_FIXTURES") ?: error("Set the fixture output directory")).apply { mkdirs() }
        fun run(vararg args: String) {
            val p = ProcessBuilder(listOf(ffmpeg!!) + args).directory(root).redirectErrorStream(true)
                .redirectOutput(java.io.File(root, "ffmpeg.log")).start()
            try { assertTrue(p.waitFor(45, java.util.concurrent.TimeUnit.SECONDS)); assertEquals(java.io.File(root, "ffmpeg.log").readText(), 0, p.exitValue()) }
            finally { p.destroyForcibly() }
        }
        run("-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=15", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "4", "-c:v", "libx264", "-g", "15", "-c:a", "aac", "-f", "hls", "-hls_time", "1", "-hls_playlist_type", "vod", "sample.m3u8")
        Fixture { request, _, _ ->
            val name = request.split(' ')[1].substringAfterLast('/')
            val file = java.io.File(root, name)
            if (file.isFile && file.parentFile == root) Reply(200, body = file.readBytes()) else Reply(404, body = ByteArray(0))
        }.use { origin -> LocalStreamServer().use { local -> WebVideoHls(local).use { hls ->
            val url = hls.prepare(track(origin.url + "/sample.m3u8"))
            run("-v", "error", "-i", url, "-map", "0:v", "-map", "0:a", "-f", "null", "-")
            run("-v", "error", "-ss", "2", "-i", url, "-t", "1", "-map", "0:v", "-map", "0:a", "-f", "null", "-")
        } } }
    }

    @Test fun rewritesNestedManifestsMapAndSegmentsAndRevokesEveryCapability() {
        val segment = ByteArray(1024) { (it % 251).toByte() }
        Fixture { request, headers, _ ->
            assertEquals("session=synthetic", headers["cookie"])
            assertNull(headers["range"])
            when {
                request.contains("/master") -> Reply(200, body = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvideo/list.m3u8?private=1\n".toByteArray())
                request.contains("/video/list") -> Reply(200, body = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MAP:URI=\"init.mp4?private=2\"\n#EXTINF:4,\nsegment.m4s?private=3\n#EXT-X-ENDLIST\n".toByteArray())
                else -> Reply(200, body = segment)
            }
        }.use { origin -> LocalStreamServer().use { local ->
            val hls = WebVideoHls(local)
            val url = hls.prepare(track(origin.url + "/master.m3u8", mapOf("Cookie" to "session=synthetic")))
            val root = read(url).toString(Charsets.UTF_8)
            assertFalse(root.contains("private="))
            val child = root.lines().first { it.startsWith("http") }
            val playlist = read(child).toString(Charsets.UTF_8)
            val media = playlist.lines().first { it.startsWith("http") }
            val init = Regex("URI=\"([^\"]+)\"").find(playlist)!!.groupValues[1]
            assertFalse(playlist.contains("private="))
            assertArrayEquals(segment, read(media)); assertArrayEquals(segment, read(init))
            hls.close()
            listOf(url, child, media, init).forEach { assertFalse(local.hasSource(it)) }
        } }
    }

    @Test fun neverForwardsAccountHeadersToAnotherOriginAndHandlesAesIdentityKeys() {
        Fixture { _, headers, _ ->
            assertNull(headers["cookie"]); assertNull(headers["authorization"])
            assertNull(headers["referer"]); assertNull(headers["x-emby-token"]); assertNull(headers["x-mediabrowser-token"])
            Reply(200, body = ByteArray(16) { 7 })
        }.use { cdn -> Fixture { _, _, _ ->
            Reply(200, body = "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-KEY:METHOD=AES-128,URI=\"${cdn.url}/key\"\n#EXTINF:1,\n${cdn.url}/segment.ts\n#EXT-X-ENDLIST\n".toByteArray())
        }.use { origin -> LocalStreamServer().use { local -> WebVideoHls(local, strictOriginHeaders = true).use { hls ->
            val text = read(hls.prepare(track(origin.url + "/list", mapOf("Cookie" to "private", "Authorization" to "private",
                "Referer" to "https://private.example/?api_key=secret", "X-Emby-Token" to "private", "X-MediaBrowser-Token" to "private")))).toString(Charsets.UTF_8)
            val key = Regex("URI=\"([^\"]+)\"").find(text)!!.groupValues[1]
            assertEquals(16, read(key).size)
            assertEquals(16, read(text.lines().first { it.startsWith("http") }).size)
        } } } }
    }

    @Test fun requestsAgainAfterACutConnectionButNotAfterARefusal() {
        val requests = java.util.concurrent.atomic.AtomicInteger()
        Fixture { request, _, _ ->
            // The host JDK silently resends a GET once after a closed connection; cut past that.
            if (request.contains("/list") && requests.incrementAndGet() <= 2) error("Connection cut")
            if (request.contains("/list")) Reply(200, body = "#EXTM3U\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n".toByteArray())
            else Reply(200, body = ByteArray(8) { 1 })
        }.use { origin -> LocalStreamServer().use { local -> WebVideoHls(local).use { hls ->
            val text = read(hls.prepare(track(origin.url + "/list"))).toString(Charsets.UTF_8)
            assertEquals(3, requests.get())
            assertEquals(8, read(text.lines().first { it.startsWith("http") }).size)
        } } }
        val refused = java.util.concurrent.atomic.AtomicInteger()
        Fixture { _, _, _ -> refused.incrementAndGet(); Reply(403, body = ByteArray(0)) }.use { origin -> LocalStreamServer().use { local ->
            WebVideoHls(local).use { hls -> assertThrows(MediaServerFailure::class.java) { hls.prepare(track(origin.url + "/list")) } }
        } }
        assertEquals(1, refused.get())
    }

    @Test fun rejectsProtectedLiveCyclicAndNonHttpManifests() {
        for (body in listOf(
            "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\"\n#EXT-X-ENDLIST\n",
            "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,KEYFORMAT=\"com.apple.streamingkeydelivery\",URI=\"key\"\n#EXT-X-ENDLIST\n",
            "#EXTM3U\n#EXTINF:1,\nsegment.ts\n",
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nlist\n",
            "#EXTM3U\n#EXTINF:1,\nfile:///secret\n#EXT-X-ENDLIST\n")) {
            Fixture { _, _, _ -> Reply(200, body = body.toByteArray()) }.use { origin -> LocalStreamServer().use { local ->
                WebVideoHls(local).use { hls -> assertThrows(Exception::class.java) { hls.prepare(track(origin.url + "/list")) } }
            } }
        }
    }
}
