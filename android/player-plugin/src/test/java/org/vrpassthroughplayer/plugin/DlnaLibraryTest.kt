package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI

class DlnaLibraryTest {
    private fun xml(body: String) = """<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:s="http://www.sec.co.kr/" xmlns:p="http://www.pv.com/pvns/">$body</DIDL-Lite>"""
    private fun item(body: String) = """<item id="v_1"><dc:title>Movie</dc:title>$body</item>"""
    private fun escape(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    private fun soap(didl: String, total: Int = Regex("<(?:item|container) ").findAll(didl).count(), update: Int = 1,
        returned: Int = Regex("<(?:item|container) ").findAll(didl).count()) =
        """<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><u:Result>${escape(didl)}</u:Result><NumberReturned>$returned</NumberReturned><TotalMatches>$total</TotalMatches><UpdateID>$update</UpdateID></u:BrowseResponse></s:Body></s:Envelope>"""
    private val description = """<root><device><friendlyName>PT server</friendlyName><UDN>uuid:pt</UDN><serviceList><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>/control/cds</controlURL></service></serviceList></device></root>"""

    private inner class CaptionFixture : java.io.Closeable {
        var mode = "full"
        var parentCaptions = true
        var parentAvailable = true
        var parentInMetadata = false
        var header = false
        var downloadAvailable = true
        var includeOther = false
        val requests = mutableListOf<String>()
        val payload = "1\n00:00:00,000 --> 00:00:02,000\nFixture subtitle\n".toByteArray()
        val fixture = MediaServerClientTest.Fixture { request, _, body ->
            when {
                request.startsWith("HEAD ") -> {
                    requests.add("head")
                    MediaServerClientTest.Reply(headers = if (header) "CaptionInfo.sec: /movie.srt\r\n" else "", body = byteArrayOf())
                }
                request.startsWith("GET ") -> MediaServerClientTest.Reply(if (downloadAvailable) 200 else 404, body = payload)
                else -> {
                    val metadata = body.contains("BrowseMetadata")
                    val id = Regex("<ObjectID>(.*?)</ObjectID>").find(body)!!.groupValues[1]
                    requests.add((if (metadata) "metadata:" else "children:") + id)
                    if ((!metadata && !parentAvailable) || (metadata && mode == "http_error"))
                        MediaServerClientTest.Reply(503, body = byteArrayOf())
                    else {
                        fun video(id: String = "v_1", captions: Boolean = true, changed: Boolean = false): String =
                            """<item id="$id"${if (metadata && parentInMetadata) " parentID=\"0\"" else ""}><dc:title>Movie</dc:title><res protocolInfo="http-get:*:video/mp4:*">/movie.mp4${if (changed) "?token=new" else ""}</res>${if (captions) "<res protocolInfo=\"http-get:*:text/srt:*\">/${if (id == "v_1") "movie" else "other"}.srt</res>" else ""}</item>"""
                        val entries = if (metadata) when (mode) {
                            "empty" -> ""
                            "omits" -> video(captions = false)
                            "changed_uri" -> video(changed = true)
                            "wrong_id" -> video(id = "other")
                            else -> video(captions = parentCaptions)
                        } else (if (mode == "removed_video") "" else video(captions = parentCaptions)) +
                            if (includeOther) video(id = "other") else ""
                        MediaServerClientTest.Reply(body = soap(xml(entries)).toByteArray())
                    }
                }
            }
        }
        var state = JSONObject().put("servers", JSONArray().put(DlnaClient.Server("id", "Fixture",
            fixture.url + "/description.xml", fixture.url + "/cds").json())).toString()
        fun library() = DlnaLibrary({ state }, { state = it })
        fun browse(library: DlnaLibrary) = library.browse("id", "0").getJSONObject(0).getString("uri")
        fun tracks(library: DlnaLibrary, uri: String) = SidecarSubtitles.forDlna(library.subtitles(uri)) { source, name ->
            val bytes = ByteArray(payload.size)
            source.open().use { assertEquals(payload.size, it.read(0, bytes, bytes.size)) }
            assertArrayEquals(payload, bytes)
            source.close()
            name
        }
        override fun close() = fixture.close()
    }

    @Test fun omittedMetadataKeepsDirectorySubtitleAfterRestart() {
        CaptionFixture().use { f ->
            val uri = f.browse(f.library())
            f.mode = "omits"
            val restored = f.library()
            assertEquals(1, f.tracks(restored, uri).size)
            assertEquals(listOf("children:0", "metadata:v_1", "children:0"), f.requests)
            assertEquals("0", JSONObject(f.state).getJSONArray("references").getJSONObject(0).getString("parent_id"))
        }
    }

    @Test fun emptyMetadataRevalidatesDirectoryInsteadOfErasingTracks() {
        CaptionFixture().use { f ->
            val library = f.library(); val uri = f.browse(library)
            f.mode = "empty"
            assertEquals(1, f.tracks(library, uri).size)
        }
    }

    @Test fun metadataUsesObjectIdAcrossVideoUrlChangesWithoutExtraDirectoryReads() {
        CaptionFixture().use { f ->
            val library = f.library(); val uri = f.browse(library)
            f.mode = "changed_uri"
            assertEquals(1, f.tracks(library, uri).size)
            assertEquals(listOf("children:0", "metadata:v_1"), f.requests)
        }
    }

    @Test fun anotherObjectWithTheSameVideoUriCannotSupplyCaptions() {
        CaptionFixture().use { f ->
            val library = f.library(); val uri = f.browse(library)
            f.mode = "wrong_id"
            assertEquals("/movie.srt", library.subtitles(uri).single().url.path)
            assertEquals(listOf("children:0", "metadata:v_1", "children:0"), f.requests)
        }
    }

    @Test fun confirmedSubtitleRemovalAndLaterAdditionAreReflectedInHistory() {
        CaptionFixture().use { f ->
            val uri = f.browse(f.library())
            f.mode = "omits"; f.parentCaptions = false
            assertTrue(f.library().subtitles(uri).isEmpty())
            f.parentCaptions = true
            assertEquals(1, f.tracks(f.library(), uri).size)
        }
    }

    @Test fun removedVideoDoesNotTakeAnotherItemsSubtitleOrItsOwnOldCache() {
        CaptionFixture().use { f ->
            val library = f.library(); val uri = f.browse(library)
            f.mode = "removed_video"; f.parentCaptions = false; f.includeOther = true
            assertTrue(library.subtitles(uri).isEmpty())
        }
    }

    @Test fun failedParentRefreshPreservesValidatedBytesButLaterRemovalClearsThem() {
        CaptionFixture().use { f ->
            val library = f.library(); val uri = f.browse(library)
            f.mode = "omits"; f.parentAvailable = false
            assertEquals(1, f.tracks(library, uri).size)
            f.parentAvailable = true; f.parentCaptions = false
            assertTrue(library.subtitles(uri).isEmpty())
        }
    }

    @Test fun legacyReferenceCanLearnParentFromMetadataAndRejectRemovedCaptions() {
        CaptionFixture().use { f ->
            val uri = f.browse(f.library())
            val data = JSONObject(f.state)
            data.getJSONArray("references").getJSONObject(0).apply { remove("parent_id"); remove("subtitle_origin") }
            f.state = data.toString()
            f.mode = "omits"; f.parentInMetadata = true; f.parentCaptions = false
            assertTrue(f.library().subtitles(uri).isEmpty())
            assertEquals("0", JSONObject(f.state).getJSONArray("references").getJSONObject(0).getString("parent_id"))
        }
    }

    @Test fun legacyReferenceWithoutParentRetainsOnlyReadableSubtitleBytes() {
        CaptionFixture().use { f ->
            val uri = f.browse(f.library())
            val data = JSONObject(f.state)
            data.getJSONArray("references").getJSONObject(0).apply { remove("parent_id"); remove("subtitle_origin") }
            f.state = data.toString(); f.mode = "omits"
            val restored = f.library()
            assertEquals(1, f.tracks(restored, uri).size)
            f.downloadAvailable = false
            assertTrue(f.tracks(restored, uri).isEmpty())
        }
    }

    @Test fun headerOnlyServersRefreshTheHeaderWithoutParentBrowseOnReplay() {
        CaptionFixture().use { f ->
            f.parentCaptions = false; f.header = true
            val library = f.library(); val uri = f.browse(library)
            assertEquals(1, f.tracks(library, uri).size)
            assertEquals(1, f.tracks(library, uri).size)
            f.header = false
            assertTrue(library.subtitles(uri).isEmpty())
            assertEquals(1, f.requests.count { it == "children:0" })
            assertEquals(3, f.requests.count { it == "head" })
        }
    }

    @Test fun completeMetadataAndHttpFailureKeepTheirExistingFastPaths() {
        CaptionFixture().use { f ->
            val library = f.library(); val uri = f.browse(library)
            assertEquals(1, f.tracks(library, uri).size)
            f.mode = "http_error"
            assertEquals(1, f.tracks(library, uri).size)
            assertEquals(listOf("children:0", "metadata:v_1", "metadata:v_1"), f.requests)
        }
    }

    @Test fun subtitlePrefixesMissingFromDidlDoNotBreakTheWholeDirectory() {
        val body = """<container id="folder"><dc:title>Folder</dc:title></container>
            <item id="with"><dc:title>Movie with subtitles</dc:title>
                <res protocolInfo="http-get:*:video/mp4:*" pv:subtitleFileUri="/movie.ass" pv:subtitleFileType="ass">/movie.mp4</res>
                <sec:CaptionInfoEx sec:type="srt">/movie.srt</sec:CaptionInfoEx></item>
            <item id="without"><dc:title>Other movie</dc:title><res protocolInfo="http-get:*:video/mp4:*">/other.mp4</res></item>"""
        val didl = """<?xml version="1.0" encoding="utf-8"?><DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/">$body</DIDL-Lite>"""
        MediaServerClientTest.Fixture { _, _, _ -> MediaServerClientTest.Reply(body = soap(didl).toByteArray()) }.use { fixture ->
            val entries = DlnaClient.browse(DlnaClient.Server("id", "test", fixture.url, fixture.url), "0")
            assertEquals(3, entries.length())
            val tracks = entries.getJSONObject(1).getJSONArray("subtitles")
            assertEquals(2, tracks.length())
            assertEquals(fixture.url + "/movie.srt", tracks.getJSONObject(0).getString("url"))
            assertEquals(fixture.url + "/movie.ass", tracks.getJSONObject(1).getString("url"))
        }
    }

    @Test fun captionNamespaceFallbackPreservesExplicitDeclarationsAndXmlValidation() {
        val video = """<item id="1"><res protocolInfo="http-get:*:video/mp4:*">http://nas/movie.mp4</res>
            <sec:CaptionInfoEx sec:type="srt">http://nas/movie.srt</sec:CaptionInfoEx></item>"""
        val foreign = """<DIDL-Lite xmlns:sec="urn:other">$video</DIDL-Lite>"""
        assertEquals(0, DlnaClient.didl(foreign).getJSONObject(0).getJSONArray("subtitles").length())
        for (bad in listOf("<DIDL-Lite><unknown:caption/></DIDL-Lite>",
            "<DIDL-Lite><item id=\"1\"><title>A & B</title></item></DIDL-Lite>",
            "<DIDL-Lite/><DIDL-Lite/>", "text<DIDL-Lite/>",
            "<!DOCTYPE DIDL-Lite [<!ENTITY x SYSTEM \"file:///private\">]><DIDL-Lite>&x;</DIDL-Lite>"))
            assertThrows(Exception::class.java) { DlnaClient.didl(bad) }
    }

    @Test fun manualLocationsValidateAndPreserveExplicitProxyPath() {
        assertEquals("http://192.168.2.10:8200", DlnaClient.address("192.168.2.10", "8200"))
        assertEquals("http://[::1]:8200", DlnaClient.address("::1", "8200"))
        assertEquals("https://nas.example:443", DlnaClient.address("nas.example", "443", "https"))
        for (port in listOf("", "0", "65536", "abc", "8200.0"))
            assertThrows(IllegalStateException::class.java) { DlnaClient.address("nas", port) }
        for (host in listOf("", "bad host", "nas:8200", "http://nas/description.xml", "user@nas"))
            assertThrows(IllegalStateException::class.java) { DlnaClient.address(host, "8200") }
        assertEquals("http://192.168.2.10:8200/description.xml", DlnaClient.descriptionLocations(" 192.168.2.10:8200 ").first())
        assertEquals(listOf("https://nas.example/proxy/device.xml?x=1"), DlnaClient.descriptionLocations("https://nas.example/proxy/device.xml?x=1"))
        assertTrue(DlnaClient.descriptionLocations("[::1]:8200").first().contains("[::1]:8200"))
        for (bad in listOf("", "ftp://nas/file", "http://user:key@nas/", "http://nas:99999/", "http://nas/#part", "bad host"))
            assertThrows(IllegalStateException::class.java) { DlnaClient.descriptionLocations(bad) }
    }

    @Test fun ptResourcesDeduplicateSecPvAndRetainLanguagesFormatsAndQueryIdentities() {
        val didl = xml(item("""<res protocolInfo="http-get:*:video/mp4:*" p:subtitleFileUri="/subs/movie.srt?mime=text/srt" p:subtitleFileType="srt">/media/movie.mp4</res>
            <res protocolInfo="http-get:*:application/x-subrip:*">/subs/movie.srt</res>
            <res protocolInfo="http-get:*:text/srt:*">/subs/movie.srt?mime=text/srt</res>
            <res protocolInfo="http-get:*:application/x-ass:*" xml:lang="zh">/subs/movie.zh.ASS</res>
            <res protocolInfo="http-get:*:application/x-ssa:*" xml:lang="ja">/subs/movie.ja.ssa</res>
            <res protocolInfo="http-get:*:text/vtt:*" xml:lang="en">/subs/movie.en.vtt</res>
            <res protocolInfo="http-get:*:text/srt:*">/caption?track=1</res>
            <res protocolInfo="http-get:*:text/srt:*">/caption?track=2</res>
            <s:CaptionInfoEx s:type="srt">/subs/movie.srt?mime=text/srt</s:CaptionInfoEx>
            <s:CaptionInfo s:type="srt">/subs/movie.srt?mime=text/srt</s:CaptionInfo>"""))
        val entries = DlnaClient.didl(didl, "http://nas:8200/description.xml")
        assertEquals(1, entries.length())
        assertEquals("http://nas:8200/media/movie.mp4", entries.getJSONObject(0).getString("uri"))
        val tracks = entries.getJSONObject(0).getJSONArray("subtitles")
        assertEquals(6, tracks.length())
        assertEquals("http://nas:8200/subs/movie.srt", tracks.getJSONObject(0).getString("url"))
        assertEquals("zh · ASS", tracks.getJSONObject(1).getString("title"))
        assertEquals("ja · SSA", tracks.getJSONObject(2).getString("title"))
        assertEquals("en · VTT", tracks.getJSONObject(3).getString("title"))
        assertNotEquals(tracks.getJSONObject(4).getString("url"), tracks.getJSONObject(5).getString("url"))
    }

    @Test fun secAndPvOnlyServersWorkAndUnsafeLinksNeverBecomeTracks() {
        for (caption in listOf("<s:CaptionInfoEx s:type=\"ass\">/captions/1</s:CaptionInfoEx>",
            "<s:CaptionInfo s:type=\"ssa\">/captions/1</s:CaptionInfo>",
            "<res protocolInfo=\"http-get:*:image/jpeg:*\" p:subtitleFileUri=\"/captions/1\" p:subtitleFileType=\"vtt\">/cover.jpg</res>")) {
            val tracks = DlnaClient.didl(xml(item("<res protocolInfo=\"http-get:*:video/mp4:*\">/movie.mp4</res>$caption")), "http://nas/desc.xml")
                .getJSONObject(0).getJSONArray("subtitles")
            assertEquals(1, tracks.length())
        }
        val unsafe = listOf("file:///private.srt", "http://user:pass@nas/a.srt", "javascript:alert(1)", "http://nas/a.srt#fragment")
        val body = unsafe.joinToString("") { "<s:CaptionInfoEx s:type=\"srt\">${escape(it)}</s:CaptionInfoEx>" }
        assertEquals(0, DlnaClient.didl(xml(item("<res protocolInfo=\"http-get:*:video/mp4:*\">http://nas/movie.mp4</res>$body")))
            .getJSONObject(0).getJSONArray("subtitles").length())
    }

    @Test fun manualServerPersistsWithoutMulticastMergesAndRollsBackFailedEdits() {
        var state = ""
        var fail = false
        var found = emptyList<DlnaClient.Server>()
        MediaServerClientTest.Fixture { request, _, _ ->
            MediaServerClientTest.Reply(if (request.contains("/rootDesc.xml")) 200 else 404, body = description.toByteArray())
        }.use { fixture ->
            fun library() = DlnaLibrary({ state }, { if (fail) error("disk full"); state = it }, { found })
            val first = library()
            val endpoint = URI(fixture.url)
            val id = first.save(JSONObject().put("host", endpoint.host).put("port", endpoint.port.toString()).put("name", "Remote NAS"))
            assertEquals("uuid:pt", id)
            assertEquals(fixture.url + "/rootDesc.xml", first.servers().getJSONObject(0).getString("location"))
            val restored = library()
            found = listOf(DlnaClient.Server(id, "Auto", fixture.url + "/other.xml", fixture.url + "/other"))
            assertEquals(1, restored.refresh().length())
            assertEquals("Remote NAS", restored.servers().getJSONObject(0).getString("name"))
            assertTrue(restored.servers().getJSONObject(0).getBoolean("manual"))
            fail = true
            assertThrows(IllegalStateException::class.java) { restored.save(JSONObject().put("id", id).put("location", fixture.url).put("name", "New")) }
            assertEquals("Remote NAS", restored.servers().getJSONObject(0).getString("name"))
            assertThrows(IllegalStateException::class.java) { restored.remove(id) }
            assertEquals(1, restored.servers().length())
            fail = false
            restored.remove(id)
            assertEquals(0, restored.servers().length())
            assertEquals(0, library().servers().length())
        }
    }

    @Test fun savedEndpointsSurviveDiscoveryFailure() {
        val row = DlnaClient.Server("id", "Saved", "http://nas/description.xml", "http://nas/cds").json()
        val library = DlnaLibrary({ JSONObject().put("servers", JSONArray().put(row)).toString() }, {}, { error("multicast blocked") })
        assertEquals("Saved", library.refresh().getJSONObject(0).getString("name"))
    }

    @Test fun namespacedDescriptionsKeepServiceVersionAcrossRestart() {
        val xml = """<d:root xmlns:d="urn:schemas-upnp-org:device-1-0"><d:URLBase>/proxy/</d:URLBase><d:device><d:friendlyName>Namespaced NAS</d:friendlyName><d:UDN>uuid:v2</d:UDN><d:service><d:serviceType>urn:schemas-upnp-org:service:ContentDirectory:2</d:serviceType><d:controlURL>cds</d:controlURL></d:service></d:device></d:root>"""
        val selected = DlnaClient.describe("http://nas:8200/description.xml", xml)!!
        assertEquals("Namespaced NAS", selected.name)
        assertEquals("http://nas:8200/proxy/cds", selected.controlUrl)
        assertEquals("urn:schemas-upnp-org:service:ContentDirectory:2", selected.serviceType)
        var endpoint = ""
        var state = ""
        var browsed = false
        MediaServerClientTest.Fixture { request, headers, body ->
            if (request.contains("/proxy/cds")) {
                assertEquals("\"urn:schemas-upnp-org:service:ContentDirectory:2#Browse\"", headers["soapaction"])
                assertTrue(body.contains("xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:2\""))
                browsed = true
                MediaServerClientTest.Reply(body = soap(this.xml("")).toByteArray())
            } else MediaServerClientTest.Reply(body = xml.toByteArray())
        }.use { fixture ->
            endpoint = fixture.url
            val library = DlnaLibrary({ state }, { state = it })
            val id = library.save(JSONObject().put("location", endpoint))
            assertEquals("Namespaced NAS", library.servers().getJSONObject(0).getString("name"))
            val restored = DlnaLibrary({ state }, {})
            assertEquals(0, restored.browse(id, "0").length())
            assertTrue(browsed)
        }
    }

    @Test fun browseReplayRefreshRemovalAndCaptionHeaderReachOriginalByteStreams() {
        var endpoint = ""
        var state = ""
        var metadata = false
        var captions = true
        var header = false
        val payload = "1\r\n00:00:00,000 --> 00:00:02,000\r\n字幕 & Subtitle\r\n".toByteArray()
        val flags = mutableListOf<String>()
        val fixture = MediaServerClientTest.Fixture { request, headers, body ->
            val path = request.split(' ')[1]
            when {
                path == "/description.xml" -> MediaServerClientTest.Reply(body = description.toByteArray())
                path == "/control/cds" -> {
                    metadata = body.contains("BrowseMetadata")
                    flags.add(if (metadata) "metadata" else "children")
                    assertTrue(body.contains("<ObjectID>${if (metadata) "v_1" else "0"}</ObjectID>"))
                    val caption = if (captions) "<res protocolInfo=\"http-get:*:application/x-subrip:*\" xml:lang=\"zh\">$endpoint/subs/movie.srt</res>" else ""
                    MediaServerClientTest.Reply(body = soap(xml(item("<res protocolInfo=\"http-get:*:video/mp4:*\">$endpoint/media/movie.mp4</res>$caption"))).toByteArray())
                }
                request.startsWith("HEAD ") -> {
                    assertEquals("1", headers["getcaptioninfo.sec"])
                    MediaServerClientTest.Reply(headers = if (header) "CaptionInfo.sec: /subs/movie.srt\r\n" else "", body = byteArrayOf())
                }
                path == "/subs/movie.srt" -> MediaServerClientTest.Reply(headers = "Content-Type: application/x-subrip\r\n", body = payload)
                else -> MediaServerClientTest.Reply(404, body = byteArrayOf())
            }
        }
        fixture.use {
            endpoint = fixture.url
            val library = DlnaLibrary({ state }, { state = it })
            val id = library.save(JSONObject().put("location", endpoint))
            val entries = library.browse(id, "0")
            val video = entries.getJSONObject(0).getString("uri")
            val restored = DlnaLibrary({ state }, { state = it })
            val links = restored.subtitles(video)
            assertTrue(metadata)
            assertEquals(1, links.size)
            val tracks = SidecarSubtitles.forDlna(links) { source, name ->
                assertEquals("subtitle-0.srt", name)
                val result = ByteArray(payload.size)
                source.open().use { reader -> assertEquals(payload.size, reader.read(0, result, result.size)) }
                assertArrayEquals(payload, result)
                source.close()
                "http://127.0.0.1/subtitle.srt"
            }
            assertEquals("zh · SRT", tracks.single().title)
            captions = false
            assertTrue(restored.subtitles(video).isEmpty())
            header = true
            assertEquals(endpoint + "/subs/movie.srt", restored.subtitles(video).single().url.toString())
            assertEquals(listOf("children", "metadata", "metadata", "children", "metadata", "children"), flags)
            assertTrue(restored.subtitles("http://unknown/video.mp4").isEmpty())
        }
    }

    @Test fun individualDownloadFailuresDoNotHideValidAssSsaOrVttBytes() {
        val originals = mapOf("ass" to "[Script Info]\n[Events]\nDialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,{\\i1}字幕{\\i0}\\NSubtitle\n".toByteArray(),
            "ssa" to "[Script Info]\nScriptType: v4.00\n[Events]\nDialogue: Marked=0,0:00:00.00,0:00:02.00,Default,,0,0,0,,字幕\n".toByteArray(),
            "vtt" to "WEBVTT\n\n00:00:00.000 --> 00:00:02.000 align:start\n<i>字幕</i> & Subtitle\n".toByteArray())
        MediaServerClientTest.Fixture { request, _, _ ->
            val ext = request.split(' ')[1].substringAfterLast('.')
            MediaServerClientTest.Reply(body = originals[ext] ?: "<html>login</html>".toByteArray())
        }.use { fixture ->
            val links = (listOf("srt") + originals.keys).map { MediaSubtitleLink(URI(fixture.url + "/movie.$it"), it, it) }
            val tracks = SidecarSubtitles.forDlna(links) { source, name ->
                val expected = originals.getValue(name.substringAfterLast('.'))
                val result = ByteArray(expected.size)
                source.open().use { it.read(0, result, result.size) }
                assertArrayEquals(expected, result)
                source.close()
                name
            }
            assertEquals(listOf("ass", "ssa", "vtt"), tracks.map { it.title })
        }
    }

    @Test fun earlyItemsOnLargePagesHaveSubtitlesAndSelectedHistorySurvivesRestart() {
        var endpoint = ""
        var state = ""
        MediaServerClientTest.Fixture { request, _, body ->
            if (request.contains("/description.xml")) MediaServerClientTest.Reply(body = description.toByteArray())
            else {
                val numbers = if (body.contains("BrowseMetadata")) listOf(0) else (0 until 1000).toList()
                val items = numbers.joinToString("") { id -> """<item id="$id"><dc:title>Movie $id</dc:title><res protocolInfo="http-get:*:video/mp4:*">$endpoint/$id.mp4</res><res protocolInfo="http-get:*:text/srt:*">$endpoint/$id.srt</res></item>""" }
                MediaServerClientTest.Reply(body = soap(xml(items)).toByteArray())
            }
        }.use { fixture ->
            endpoint = fixture.url
            val library = DlnaLibrary({ state }, { state = it })
            val id = library.save(JSONObject().put("location", endpoint))
            assertEquals(1000, library.browse(id, "0").length())
            assertEquals(256, JSONObject(state).getJSONArray("references").length())
            val video = "$endpoint/0.mp4"
            assertEquals("$endpoint/0.srt", library.subtitles(video).single().url.toString())
            val restored = DlnaLibrary({ state }, {})
            assertEquals("$endpoint/0.srt", restored.subtitles(video).single().url.toString())
        }
    }

    @Test fun completeBrowseIncludesLaterPagesAndOffsetsCountUnsupportedItems() {
        val offsets = mutableListOf<Int>()
        MediaServerClientTest.Fixture { _, _, body ->
            assertTrue(body.contains("<SortCriteria></SortCriteria>")) // Works without server sort capabilities.
            val offset = Regex("<StartingIndex>([0-9]+)</StartingIndex>").find(body)!!.groupValues[1].toInt()
            offsets.add(offset)
            val children = when (offset) {
                0 -> """<container id="10"><dc:title>Folder10</dc:title></container><item id="audio"><dc:title>Audio</dc:title><res protocolInfo="http-get:*:audio/mpeg:*">/a.mp3</res></item>"""
                2 -> """<item id="video"><dc:title>Movie10</dc:title><res protocolInfo="http-get:*:video/mp4:*">/v.mp4</res></item><container id="2"><dc:title>Folder2</dc:title></container>"""
                else -> error("Wrong offset $offset")
            }
            // The server caps each response to two, even though the client requested 1000.
            MediaServerClientTest.Reply(body = soap(xml(children), total = 4).toByteArray())
        }.use { fixture ->
            val server = DlnaClient.Server("id", "test", fixture.url, fixture.url)
            val entries = DlnaClient.browse(server, "0")
            assertEquals(listOf(0, 2), offsets)
            assertEquals(listOf("10", "2", "video"), (0 until entries.length()).map { entries.getJSONObject(it).getString("id") })
            assertEquals(fixture.url + "/v.mp4", entries.getJSONObject(2).getString("uri"))
        }
    }

    @Test fun serversWithoutCountsReadUntilEmptyRatherThanAssumingShortPageComplete() {
        val offsets = mutableListOf<Int>()
        MediaServerClientTest.Fixture { _, _, body ->
            val offset = Regex("<StartingIndex>([0-9]+)</StartingIndex>").find(body)!!.groupValues[1].toInt()
            offsets.add(offset)
            val children = if (offset < 2) """<container id="$offset"><dc:title>Folder$offset</dc:title></container>""" else ""
            val response = soap(xml(children)).replace(Regex("<(NumberReturned|TotalMatches|UpdateID)>.*?</\\1>"), "")
            MediaServerClientTest.Reply(body = response.toByteArray())
        }.use { fixture ->
            assertEquals(2, DlnaClient.browse(DlnaClient.Server("id", "test", fixture.url, fixture.url), "0").length())
            assertEquals(listOf(0, 1, 2), offsets)
        }
    }

    @Test fun repeatedChangedIncompleteOversizedAndFailedPagesNeverReturnPartialListing() {
        for (failure in listOf("repeat", "update", "total", "empty", "count", "oversize", "http")) {
            val offsets = mutableListOf<Int>()
            MediaServerClientTest.Fixture { _, _, body ->
                val offset = Regex("<StartingIndex>([0-9]+)</StartingIndex>").find(body)!!.groupValues[1].toInt()
                offsets.add(offset)
                if (offset > 0 && failure == "http") MediaServerClientTest.Reply(503, body = byteArrayOf())
                else {
                    val children = if (offset > 0 && failure == "empty") "" else
                        """<container id="${if (failure == "repeat") 0 else offset}"><dc:title>Folder</dc:title></container>"""
                    MediaServerClientTest.Reply(body = soap(xml(children),
                        total = if (failure == "oversize") 20_001 else if (offset > 0 && failure == "total") 3 else 2,
                        update = if (offset > 0 && failure == "update") 2 else 1,
                        returned = if (offset > 0 && failure == "count") 2 else if (children.isEmpty()) 0 else 1).toByteArray())
                }
            }.use { fixture ->
                assertThrows(Exception::class.java) { DlnaClient.browse(DlnaClient.Server("id", "test", fixture.url, fixture.url), "0") }
                assertEquals(if (failure == "oversize") listOf(0) else listOf(0, 1), offsets)
            }
        }
    }

    @Test fun pagedDirectoryKeepsEarlySubtitleReferencesInMemoryAndHistory() {
        var endpoint = ""
        var state = ""
        val offsets = mutableListOf<Int>()
        MediaServerClientTest.Fixture { _, _, body ->
            val metadata = body.contains("BrowseMetadata")
            val offset = Regex("<StartingIndex>([0-9]+)</StartingIndex>").find(body)!!.groupValues[1].toInt()
            if (!metadata) offsets.add(offset)
            val end = if (metadata) 1 else minOf(offset + 1000, 2100)
            val items = (offset until end).joinToString("") { id -> """<item id="$id"><dc:title>Movie$id</dc:title><res protocolInfo="http-get:*:video/mp4:*">$endpoint/$id.mp4</res><res protocolInfo="http-get:*:text/srt:*">$endpoint/$id.srt</res></item>""" }
            MediaServerClientTest.Reply(body = soap(xml(items), total = if (metadata) 1 else 2100).toByteArray())
        }.use { fixture ->
            endpoint = fixture.url
            val server = DlnaClient.Server("id", "test", endpoint, endpoint)
            state = JSONObject().put("servers", JSONArray().put(server.json())).toString()
            val library = DlnaLibrary({ state }, { state = it })
            assertEquals(2100, library.browse("id", "0").length())
            assertEquals(listOf(0, 1000, 2000), offsets)
            assertEquals(256, JSONObject(state).getJSONArray("references").length())
            assertEquals("$endpoint/0.srt", library.subtitles("$endpoint/0.mp4").single().url.toString())
            assertEquals("$endpoint/0.srt", DlnaLibrary({ state }, {}).subtitles("$endpoint/0.mp4").single().url.toString())
            assertEquals(listOf(0, 1000, 2000), offsets) // BrowseMetadata remains a single-item request.
        }
    }
}
