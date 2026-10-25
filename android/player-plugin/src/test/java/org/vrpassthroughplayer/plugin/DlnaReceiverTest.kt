package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.InetAddress
import java.net.Socket
import java.util.UUID

class DlnaReceiverTest {
    private val peer = "127.0.0.1"
    private fun set(renderer: DlnaRenderer, uri: String = "http://192.168.0.5/movie.mp4") = renderer.action("AVTransport", "SetAVTransportURI", mapOf("InstanceID" to "0", "CurrentURI" to uri, "CurrentURIMetaData" to "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><item><dc:title>A &amp; B</dc:title></item></DIDL-Lite>"), peer)
    private fun play(renderer: DlnaRenderer) = renderer.action("AVTransport", "Play", mapOf("InstanceID" to "0", "Speed" to "1"), peer)
    private fun fault(code: Int, block: () -> Unit) { try { block(); fail("Expected fault") } catch (e: DlnaRenderer.Fault) { assertEquals(code, e.code) } }
    private fun command(r: DlnaRenderer, name: String, extra: Map<String, String> = emptyMap(), sender: String = peer) =
        r.action("AVTransport", name, mapOf("InstanceID" to "0") + extra, sender)
    private fun next(r: DlnaRenderer, uri: String = "http://192.168.0.5/next.mp4", metadata: String = "") =
        command(r, "SetNextAVTransportURI", mapOf("NextURI" to uri, "NextURIMetaData" to metadata))
    private fun start(r: DlnaRenderer): Long {
        set(r); play(r); val id = r.poll().getLong("pending_token"); r.accept(id); return id
    }
    @Test fun presetBeforePlayIsReportedAndConsumedOnlyAfterAcceptance() {
        val r = DlnaRenderer(); set(r)
        val uri = "http://192.168.0.5/next.mp4?a=1&b=2"
        val metadata = "<DIDL-Lite><item><title>Next &amp; title</title></item></DIDL-Lite>"
        next(r, uri, metadata)
        assertEquals(uri, command(r, "GetMediaInfo")["NextURI"])
        assertEquals(metadata, command(r, "GetMediaInfo")["NextURIMetaData"])
        val event = DlnaRenderer.xml(r.eventBody("AVTransport")).getElementsByTagName("LastChange").item(0).textContent
        assertTrue(event.contains("NextAVTransportURI")); assertTrue(event.contains("a=1&amp;b=2"))
        play(r); val first = r.poll().getLong("pending_token"); r.accept(first)
        assertTrue(r.poll().getBoolean("has_next"))
        assertEquals(1, r.navigate(first, 1))
        val batch = r.poll(); val offer = batch.getJSONArray("events").getJSONObject(0)
        assertEquals(first, offer.getLong("from_token")); assertEquals("Next & title", offer.getString("title"))
        assertEquals(first, batch.getLong("active_token")); assertTrue(batch.getBoolean("navigation_pending"))
        assertEquals(-1, r.navigate(first, 1)) // repeated press cannot consume two resources
        val accepted = r.accept(offer.getLong("token"))
        assertEquals(uri, accepted.getString("uri")); assertTrue(accepted.getBoolean("has_previous"))
        assertFalse(accepted.getBoolean("has_next")); assertEquals("", command(r, "GetMediaInfo")["NextURI"])
        r.publish(JSONObject().put("token", first).put("state", "PLAYING").put("duration_ms", 999000))
        assertEquals("00:00:00", command(r, "GetMediaInfo")["MediaDuration"])
    }
    @Test fun previousAndNextRoundTripPreservesTheFollowingPreset() {
        val r = DlnaRenderer(); val a = start(r); next(r, "http://192.168.0.5/b.mp4")
        assertEquals(1, r.navigate(a, 1)); val b = r.poll().getLong("pending_token"); r.accept(b)
        next(r, "http://192.168.0.5/c.mp4")
        command(r, "Previous")
        val back = r.accept(r.poll().getLong("pending_token"))
        assertTrue(back.getString("uri").endsWith("movie.mp4")); assertFalse(back.getBoolean("has_previous"))
        assertTrue(command(r, "GetMediaInfo")["NextURI"]!!.endsWith("b.mp4"))
        command(r, "Next"); val forward = r.accept(r.poll().getLong("pending_token"))
        assertTrue(forward.getString("uri").endsWith("b.mp4"))
        assertTrue(command(r, "GetMediaInfo")["NextURI"]!!.endsWith("c.mp4"))
        command(r, "Next"); assertTrue(r.accept(r.poll().getLong("pending_token")).getString("uri").endsWith("c.mp4"))
        fault(711) { command(r, "Next") }
    }
    @Test fun presetCanBeReplacedClearedAndValidatedWithoutLosingValidValue() {
        val r = DlnaRenderer(); start(r); next(r)
        for (uri in listOf("file:///secret", "http://127.0.0.1/local", "http://user:pass@host/x")) {
            fault(716) { next(r, uri) }
            assertTrue(command(r, "GetMediaInfo")["NextURI"]!!.endsWith("next.mp4"))
        }
        fault(402) { next(r, metadata = "x".repeat(32769)) }
        next(r, "http://192.168.0.5/replaced.mp4")
        assertTrue(command(r, "GetCurrentTransportActions")["Actions"]!!.contains("Next"))
        next(r, "")
        assertEquals("", command(r, "GetMediaInfo")["NextURI"])
        assertFalse(r.poll().getBoolean("has_next")); fault(711) { command(r, "Next") }
        fault(711) { command(r, "Previous") }
    }
    @Test fun nextWithoutPresetFallsBackOnlyForSeekableCurrentResource() {
        val r = DlnaRenderer(); val id = start(r)
        fault(711) { command(r, "Next") }
        r.publish(JSONObject().put("token", id).put("state", "PLAYING").put("duration_ms", 90000).put("seekable", true))
        command(r, "Next")
        val event = r.poll().getJSONArray("events").getJSONObject(0)
        assertEquals("next_end", event.getString("action")); assertEquals(id, event.getLong("token"))
        assertEquals(0, r.navigate(id, 1)); fault(711) { command(r, "Previous") }
    }
    @Test fun navigationRetainsProtocolPauseAndPendingPlayPauseIntent() {
        val r = DlnaRenderer(); val id = start(r); next(r)
        r.publish(JSONObject().put("token", id).put("state", "PAUSED_PLAYBACK"))
        command(r, "Next"); val pending = r.poll().getLong("pending_token")
        play(r); command(r, "Pause")
        assertFalse(r.accept(pending).getBoolean("playing"))
        command(r, "Previous"); play(r)
        assertTrue(r.accept(r.poll().getLong("pending_token")).getBoolean("playing"))
    }
    @Test fun nextFromStoppedRemainsStoppedUntilPlay() {
        val r = DlnaRenderer(); val id = start(r); next(r)
        r.publish(JSONObject().put("token", id).put("state", "STOPPED"))
        command(r, "Next"); val target = r.poll().getLong("pending_token")
        assertFalse(r.accept(target).getBoolean("playing"))
        r.publish(JSONObject().put("token", target).put("state", "PAUSED_PLAYBACK"))
        assertEquals("STOPPED", command(r, "GetTransportInfo")["CurrentTransportState"])
        r.publish(JSONObject().put("token", target).put("state", "PLAYING")) // Headset Play, without a SOAP command.
        assertEquals("PLAYING", command(r, "GetTransportInfo")["CurrentTransportState"])
        r.publish(JSONObject().put("token", target).put("state", "PAUSED_PLAYBACK"))
        assertEquals("PAUSED_PLAYBACK", command(r, "GetTransportInfo")["CurrentTransportState"])
    }
    @Test fun onlyVerifiedEofAdvancesAndDuplicateOldEofCannotSkipAgain() {
        val r = DlnaRenderer(); val id = start(r); next(r)
        r.publish(JSONObject().put("token", id).put("state", "STOPPED"))
        assertEquals(0, r.poll().getLong("pending_token"))
        r.publish(JSONObject().put("token", id).put("state", "STOPPED").put("ended", true).put("error", true))
        assertEquals(0, r.poll().getLong("pending_token"))
        val eof = JSONObject().put("token", id).put("state", "STOPPED").put("ended", true)
        r.publish(eof); r.publish(eof)
        val batch = r.poll(); assertEquals(1, batch.getJSONArray("events").length())
        val second = r.accept(batch.getLong("pending_token")); assertTrue(second.getBoolean("playing"))
        next(r, "http://192.168.0.5/c.mp4"); r.publish(eof)
        assertEquals(0, r.poll().getLong("pending_token"))
    }
    @Test fun foreignOffersAndStaleTokensCannotConsumeTheQueue() {
        val r = DlnaRenderer(); val id = start(r); next(r)
        val foreign = "192.168.0.20"
        for (action in listOf("Next", "Previous", "SetNextAVTransportURI")) fault(701) { command(r, action, sender = foreign) }
        assertEquals(-1, r.navigate(id + 1, 1))
        command(r, "SetAVTransportURI", mapOf("CurrentURI" to "http://192.168.0.20/other.mp4"), foreign)
        assertEquals(-1, r.navigate(id, 1))
        assertEquals("", command(r, "GetMediaInfo")["NextURI"])
        r.reject(r.poll().getLong("pending_token"))
        assertTrue(command(r, "GetMediaInfo")["NextURI"]!!.endsWith("next.mp4"))
        command(r, "SetAVTransportURI", mapOf("CurrentURI" to "http://192.168.0.20/other.mp4"), foreign)
        command(r, "Play", mapOf("Speed" to "1"), foreign)
        val accepted = r.accept(r.poll().getLong("pending_token"))
        assertFalse(accepted.getBoolean("has_previous")); assertFalse(accepted.getBoolean("has_next"))
    }
    @Test fun replacementUriKeepsOnlySameControllerHistoryAndItsOwnPreset() {
        val r = DlnaRenderer(); start(r); next(r, "http://192.168.0.5/old-next.mp4")
        set(r, "http://192.168.0.5/new.mp4"); next(r, "http://192.168.0.5/new-next.mp4"); play(r)
        val accepted = r.accept(r.poll().getLong("pending_token"))
        assertTrue(accepted.getBoolean("has_previous")); assertTrue(accepted.getBoolean("has_next"))
        assertTrue(command(r, "GetMediaInfo")["NextURI"]!!.endsWith("new-next.mp4"))
        command(r, "Previous")
        assertTrue(r.accept(r.poll().getLong("pending_token")).getString("uri").endsWith("movie.mp4"))
        command(r, "Next"); r.accept(r.poll().getLong("pending_token"))
        assertTrue(command(r, "GetMediaInfo")["NextURI"]!!.endsWith("new-next.mp4"))
    }
    @Test fun expiredRejectedAndStoppedNavigationLeavesNoStraySwitch() {
        var now = 0L; val r = DlnaRenderer { now }; val id = start(r); next(r)
        r.navigate(id, 1); val pending = r.poll().getLong("pending_token"); now += 60001
        assertEquals(0, r.accept(pending).length()); assertEquals(1, r.navigate(id, 1))
        r.reject(r.poll().getLong("pending_token")); assertEquals(1, r.navigate(id, 1))
        command(r, "Stop"); val batch = r.poll()
        assertEquals(0, batch.getLong("pending_token")); assertEquals("stop", batch.getJSONArray("events").getJSONObject(0).getString("action"))
        r.finish(id)
        assertFalse(r.poll().getBoolean("has_previous")); assertEquals("", command(r, "GetMediaInfo")["NextURI"])
        assertEquals(-1, r.navigate(id, 1))
    }
    @Test fun fullEventQueueDoesNotLosePresetAndHistoryIsBounded() {
        val r = DlnaRenderer(); var id = start(r); next(r)
        repeat(64) { play(r) }; fault(501) { r.navigate(id, 1) }
        assertEquals(0, r.poll().getLong("pending_token")); assertEquals(1, r.navigate(id, 1))
        id = r.poll().getLong("pending_token"); r.accept(id)
        repeat(40) { i ->
            next(r, "http://192.168.0.5/$i.mp4"); assertEquals(1, r.navigate(id, 1))
            id = r.poll().getLong("pending_token"); r.accept(id)
        }
        repeat(32) { assertEquals(1, r.navigate(id, -1)); id = r.poll().getLong("pending_token"); r.accept(id) }
        assertEquals(0, r.navigate(id, -1))
        r.detach(); assertFalse(r.poll().getBoolean("has_next")); assertFalse(r.poll().getBoolean("has_previous"))
    }
    @Test fun offerWaitsForPlayAndHeadsetAcceptance() {
        val r = DlnaRenderer(); set(r)
        assertEquals(0, r.poll().getJSONArray("events").length())
        play(r); play(r)
        val events = r.poll().getJSONArray("events"); assertEquals(1, events.length())
        val offer = events.getJSONObject(0); assertEquals("A & B", offer.getString("title"))
        assertEquals(0, r.poll().getLong("active_token"))
        assertEquals("TRANSITIONING", r.action("AVTransport", "GetTransportInfo", mapOf("InstanceID" to "0"), peer)["CurrentTransportState"])
        assertEquals(offer.getLong("token"), r.accept(offer.getLong("token")).getLong("token"))
        assertEquals(0, r.accept(offer.getLong("token")).length())
    }
    @Test fun rejectedAndExpiredOffersNeverTakeOver() {
        var now = 10L; val r = DlnaRenderer { now }; set(r); play(r)
        val id = r.poll().getLong("pending_token"); r.reject(id); assertEquals(0, r.accept(id).length())
        set(r); play(r); val next = r.poll().getLong("pending_token"); now += 60001
        assertEquals(0, r.accept(next).length()); assertEquals(0, r.poll().getJSONArray("events").length())
    }
    @Test fun localSelectionRevokesEveryOldCommand() {
        val r = DlnaRenderer(); set(r); play(r); val id = r.poll().getLong("pending_token"); r.accept(id)
        r.action("AVTransport", "Pause", mapOf("InstanceID" to "0"), peer)
        r.detach(); assertEquals(0, r.poll().getJSONArray("events").length())
        fault(701) { play(r) }; r.publish(JSONObject().put("token", id).put("state", "PLAYING"))
        assertEquals("NO_MEDIA_PRESENT", r.action("AVTransport", "GetTransportInfo", mapOf("InstanceID" to "0"), peer)["CurrentTransportState"])
    }
    @Test fun positionAndStateComeFromPlayerAndSurviveDecoderChanges() {
        val r = DlnaRenderer(); set(r); play(r); val id = r.poll().getLong("pending_token"); r.accept(id)
        r.publish(JSONObject().put("token", id).put("state", "PAUSED_PLAYBACK").put("position_ms", 83000).put("duration_ms", 120000).put("seekable", true))
        assertEquals("00:01:23", r.action("AVTransport", "GetPositionInfo", mapOf("InstanceID" to "0"), peer)["RelTime"])
        r.action("AVTransport", "Seek", mapOf("InstanceID" to "0", "Unit" to "REL_TIME", "Target" to "00:01:40"), peer)
        assertEquals(100000L, r.poll().getJSONArray("events").getJSONObject(0).getLong("position_ms"))
        fault(711) { r.action("AVTransport", "Seek", mapOf("InstanceID" to "0", "Unit" to "REL_TIME", "Target" to "00:03:00"), peer) }
        fault(701) { r.action("AVTransport", "Stop", mapOf("InstanceID" to "0"), "192.168.0.20") }
    }
    @Test fun seekBeforeAcceptanceIsPreservedAndLiveSeekIsRejected() {
        val r = DlnaRenderer(); set(r); play(r); val id = r.poll().getLong("pending_token")
        r.action("AVTransport", "Seek", mapOf("InstanceID" to "0", "Unit" to "REL_TIME", "Target" to "00:02:00"), peer)
        assertEquals(120000L, r.accept(id).getLong("start_ms"))
        fault(711) { r.action("AVTransport", "Seek", mapOf("InstanceID" to "0", "Unit" to "REL_TIME", "Target" to "00:00:01"), peer) }
    }
    @Test fun pendingMovieDoesNotInheritOldProgressOrReplaceUntilAccepted() {
        val r = DlnaRenderer(); set(r); play(r); val old = r.poll().getLong("pending_token"); r.accept(old)
        r.publish(JSONObject().put("token", old).put("state", "PLAYING").put("position_ms", 45000).put("duration_ms", 90000))
        set(r, "http://192.168.0.5/new.mp4"); play(r)
        val status = r.poll(); assertEquals(old, status.getLong("active_token"))
        val info = r.action("AVTransport", "GetPositionInfo", mapOf("InstanceID" to "0"), peer)
        assertEquals("00:00:00", info["TrackDuration"]); assertEquals("00:00:00", info["RelTime"])
        r.reject(status.getLong("pending_token"))
        assertEquals("00:00:45", r.action("AVTransport", "GetPositionInfo", mapOf("InstanceID" to "0"), peer)["RelTime"])
    }
    @Test fun stopThenNewUriInOneBatchKeepsNewOffer() {
        val r = DlnaRenderer(); set(r); play(r); val old = r.poll().getLong("pending_token"); r.accept(old)
        r.action("AVTransport", "Stop", mapOf("InstanceID" to "0"), peer)
        set(r, "http://192.168.0.5/next.mp4"); play(r)
        val events = r.poll().getJSONArray("events")
        assertEquals("stop", events.getJSONObject(0).getString("action")); assertEquals("request", events.getJSONObject(1).getString("action"))
        val next = events.getJSONObject(1).getLong("token")
        r.finish(old)
        assertEquals("http://192.168.0.5/next.mp4", r.accept(next).getString("uri"))
        r.finish(old); assertEquals(next, r.poll().getLong("active_token"))
    }
    @Test fun stopBeforeFirstUriSucceeds() {
        val r = DlnaRenderer()
        assertTrue(r.action("AVTransport", "Stop", mapOf("InstanceID" to "0"), peer).isEmpty())
        fault(701) { r.action("AVTransport", "Pause", mapOf("InstanceID" to "0"), peer) }
    }
    @Test fun headsetLocalSourcesAreRefused() {
        for (uri in listOf("http://localhost/a.mp4", "http://127.0.0.1:5244/d/a.mp4", "http://[::1]/a", "http://169.254.1.1/a", "http://127.1/a", "http://2130706433/a", "http://0x7f.1/a", "http://0.0.0.0/a"))
            assertFalse(uri, DlnaRenderer.validUri(uri))
        for (uri in listOf("http://192.0.2.7:8080/a.mp4", "http://198.51.100.7/upgcxcode/a.mp4?ua=tvproj", "https://cdn.example.com/a.mp4", "http://cdn1.example.com/a"))
            assertTrue(uri, DlnaRenderer.validUri(uri))
    }
    @Test fun absoluteSeekIsAccepted() {
        val r = DlnaRenderer(); set(r); play(r); val id = r.poll().getLong("pending_token"); r.accept(id)
        r.publish(JSONObject().put("token", id).put("state", "PLAYING").put("duration_ms", 120000).put("seekable", true))
        r.action("AVTransport", "Seek", mapOf("InstanceID" to "0", "Unit" to "ABS_TIME", "Target" to "00:01:00"), peer)
        assertEquals(60000L, r.poll().getJSONArray("events").getJSONObject(0).getLong("position_ms"))
    }
    @Test fun rendererOutlivesNetworkAndPortIsReused() {
        val renderer = DlnaRenderer(); set(renderer); play(renderer)
        val first = DlnaReceiver("uuid:${UUID.randomUUID()}", renderer = renderer); first.start(InetAddress.getByName(peer), false)
        val deadline = System.currentTimeMillis() + 5000; while (first.port == 0 && System.currentTimeMillis() < deadline) Thread.sleep(10)
        val port = first.port; first.close(); Thread.sleep(100)
        assertTrue(renderer.poll().getLong("pending_token") > 0)
        val second = DlnaReceiver("uuid:${UUID.randomUUID()}", renderer = renderer); second.start(InetAddress.getByName(peer), false, port)
        try { val until = System.currentTimeMillis() + 5000; while (second.port == 0 && System.currentTimeMillis() < until) Thread.sleep(10); assertEquals(port, second.port) }
        finally { second.close() }
    }
    @Test fun hostileInputAndQueueAreBounded() {
        assertFalse(DlnaRenderer.validUri("file:///sdcard/movie.mp4")); assertFalse(DlnaRenderer.validUri("http://user:password@host/movie"))
        assertNull(DlnaRenderer.parseTime("00:99:00")); assertNull(DlnaRenderer.parseTime("999:59:59"))
        assertTrue(runCatching { DlnaRenderer.xml("<!DOCTYPE x [<!ENTITY f SYSTEM 'file:///secret'>]><x>&f;</x>") }.isFailure)
        val r = DlnaRenderer(); set(r); play(r); r.accept(r.poll().getLong("pending_token"))
        repeat(64) { play(r) }; fault(501) { play(r) }
        assertEquals(64, r.poll().getJSONArray("events").length())
    }
    private fun server(block: (DlnaReceiver) -> Unit) {
        val receiver = DlnaReceiver("uuid:${UUID.randomUUID()}")
        receiver.start(InetAddress.getByName(peer), false)
        try { val deadline = System.currentTimeMillis() + 5000; while (receiver.port == 0 && System.currentTimeMillis() < deadline) Thread.sleep(10)
            assertTrue(receiver.port > 0); block(receiver)
        } finally { receiver.close() }
    }
    private fun request(receiver: DlnaReceiver, method: String, path: String, headers: String = "", body: String = ""): String = Socket(peer, receiver.port).use {
        it.soTimeout = 5000
        val bytes = body.toByteArray()
        it.getOutputStream().apply { write("$method $path HTTP/1.1\r\nHost: $peer\r\nContent-Length: ${bytes.size}\r\n$headers\r\n".toByteArray()); write(bytes); flush() }
        it.getInputStream().bufferedReader().readText()
    }
    @Test fun descriptionAndScpdDescribeEveryAction() = server { r ->
        val device = request(r, "GET", "/device.xml"); assertTrue(device.startsWith("HTTP/1.1 200")); assertTrue(device.contains("MediaRenderer:1"))
        for (service in DlnaReceiver.SERVICES) {
            val response = request(r, "GET", "/$service.xml"); assertTrue(response.startsWith("HTTP/1.1 200"))
            val xml = DlnaRenderer.xml(response.substringAfter("\r\n\r\n")); assertEquals(DlnaReceiver.actions(service).size, xml.getElementsByTagName("action").length)
        }
        val avt = DlnaReceiver.actions("AVTransport")
        assertTrue(avt.keys.containsAll(listOf("Next", "Previous", "SetNextAVTransportURI")))
        for (name in listOf("NextURI", "NextURIMetaData")) {
            assertEquals(avt.getValue("SetNextAVTransportURI").first { it.name == name }.variable,
                avt.getValue("GetMediaInfo").first { it.name == name }.variable)
        }
    }
    @Test fun realSoapPresetNextPreviousAndClearing() = server { r ->
        fun soap(name: String, args: String = ""): String {
            val service = DlnaReceiver.serviceType("AVTransport")
            val body = DlnaReceiver.envelope("<u:$name xmlns:u=\"$service\"><InstanceID>0</InstanceID>$args</u:$name>")
            return request(r, "POST", "/AVTransport/control", "SOAPAction: \"$service#$name\"\r\n", body)
        }
        val id = start(r.renderer)
        assertTrue(soap("SetNextAVTransportURI", "<NextURI>http://192.168.0.5/soap.mp4?a=1&amp;b=2</NextURI><NextURIMetaData/>").startsWith("HTTP/1.1 200"))
        assertTrue(soap("GetMediaInfo").contains("<NextURI>http://192.168.0.5/soap.mp4?a=1&amp;b=2</NextURI>"))
        assertTrue(soap("Next").startsWith("HTTP/1.1 200"))
        val batch = r.renderer.poll(); assertEquals(id, batch.getLong("active_token"))
        assertEquals("http://192.168.0.5/soap.mp4?a=1&b=2", r.renderer.accept(batch.getLong("pending_token")).getString("uri"))
        assertTrue(soap("Previous").startsWith("HTTP/1.1 200"))
        assertTrue(r.renderer.accept(r.renderer.poll().getLong("pending_token")).getString("uri").endsWith("movie.mp4"))
        assertTrue(soap("SetNextAVTransportURI", "<NextURI/><NextURIMetaData/>").startsWith("HTTP/1.1 200"))
        assertTrue(soap("GetMediaInfo").contains("<NextURI></NextURI>"))
        assertTrue(soap("Next").contains("<errorCode>711</errorCode>"))
        assertTrue(soap("SetNextAVTransportURI", "<NextURIMetaData/>").contains("<errorCode>402</errorCode>"))
    }
    @Test fun realSoapDispatchAndFaults() = server { r ->
        val service = DlnaReceiver.serviceType("AVTransport")
        val body = DlnaReceiver.envelope("<u:SetAVTransportURI xmlns:u=\"$service\"><InstanceID>0</InstanceID><CurrentURI>http://192.168.0.5/a.mp4?a=1&amp;b=2</CurrentURI><CurrentURIMetaData/></u:SetAVTransportURI>")
        val response = request(r, "POST", "/AVTransport/control", "SOAPAction: \"$service#SetAVTransportURI\"\r\n", body)
        assertTrue(response.startsWith("HTTP/1.1 200")); assertTrue(r.renderer.poll().getLong("pending_token") > 0)
        val bad = request(r, "POST", "/AVTransport/control", "SOAPAction: \"$service#Stop\"\r\n", body)
        assertTrue(bad.startsWith("HTTP/1.1 500")); assertTrue(bad.contains("<errorCode>401</errorCode>"))
    }
    @Test fun vendorArgumentsAreIgnored() = server { r ->
        val service = DlnaReceiver.serviceType("AVTransport")
        // Bilibili (Platinum) appends SourceId/ExtendData to SetAVTransportURI.
        val body = DlnaReceiver.envelope("<u:SetAVTransportURI xmlns:u=\"$service\"><InstanceID>0</InstanceID><CurrentURI>http://192.168.0.5/a.mp4</CurrentURI><CurrentURIMetaData></CurrentURIMetaData><SourceId></SourceId><ExtendData></ExtendData></u:SetAVTransportURI>")
        val response = request(r, "POST", "/AVTransport/control", "SOAPAction: \"$service#SetAVTransportURI\"\r\n", body)
        assertTrue(response.startsWith("HTTP/1.1 200")); assertTrue(r.renderer.poll().getLong("pending_token") > 0)
        val missing = DlnaReceiver.envelope("<u:Play xmlns:u=\"$service\"><InstanceID>0</InstanceID></u:Play>")
        assertTrue(request(r, "POST", "/AVTransport/control", "SOAPAction: \"$service#Play\"\r\n", missing).contains("<errorCode>717</errorCode>"))
    }
    @Test fun http10AndRepeatedHeadersAreTolerated() = server { r ->
        val old = Socket(peer, r.port).use { it.soTimeout = 5000; it.getOutputStream().write("GET /device.xml HTTP/1.0\r\n\r\n".toByteArray()); it.getInputStream().bufferedReader().readText() }
        assertTrue(old.startsWith("HTTP/1.1 200"))
        assertTrue(request(r, "GET", "/device.xml", "User-Agent: a\r\nUser-Agent: b\r\n").startsWith("HTTP/1.1 200"))
        assertTrue(request(r, "GET", "/device.xml", "Content-Length: 0\r\n").startsWith("HTTP/1.1 400"))
    }
    @Test fun subscriptionCallbackMustBelongToController() = server { r ->
        val response = request(r, "SUBSCRIBE", "/AVTransport/event", "NT: upnp:event\r\nCALLBACK: <http://192.168.0.99:1234/event>\r\n")
        assertTrue(response.startsWith("HTTP/1.1 412"))
    }
    @Test fun subscriptionReceivesInitialAndChangedTransportState() = server { r ->
        java.net.ServerSocket(0, 4, InetAddress.getByName(peer)).use { callbacks ->
            callbacks.soTimeout = 5000
            val response = request(r, "SUBSCRIBE", "/AVTransport/event", "NT: upnp:event\r\nCALLBACK: <http://$peer:${callbacks.localPort}/event>\r\n")
            assertTrue(response.startsWith("HTTP/1.1 200"))
            fun notification(): String = callbacks.accept().use { socket ->
                socket.soTimeout = 2000; val reader = socket.getInputStream().bufferedReader(); val start = reader.readLine(); val headers = mutableMapOf<String, String>()
                while (true) { val line = reader.readLine(); if (line.isEmpty()) break; headers[line.substringBefore(':').lowercase()] = line.substringAfter(':').trim() }
                val body = CharArray(headers.getValue("content-length").toInt()); var count = 0; while (count < body.size) { val n = reader.read(body, count, body.size-count); require(n > 0); count += n }
                socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".toByteArray()); start + headers + String(body)
            }
            assertTrue(notification().contains("NO_MEDIA_PRESENT"))
            set(r.renderer); play(r.renderer); val id = r.renderer.poll().getLong("pending_token"); r.renderer.accept(id)
            r.renderer.publish(JSONObject().put("token", id).put("state", "PAUSED_PLAYBACK"))
            assertTrue(notification().contains("PAUSED_PLAYBACK"))
            next(r.renderer, "http://192.168.0.5/notified.mp4")
            val presetEvent = notification()
            assertTrue(presetEvent.contains("NextAVTransportURI")); assertTrue(presetEvent.contains("notified.mp4"))
        }
    }
}
