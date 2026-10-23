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
        }
    }
}
