package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger

class PdfCloudProvidersTest {
    private val mount = "/12345678-1234-1234-1234-123456789abc"

    @Test fun savedFileIdentityIsBoundToOriginalUriAndContainsNoTicket() {
        val uri = "cloud://account/Comics/book.pdf"
        val file = CloudFile("book.pdf",false,3145925,"/Comics/book.pdf",objectId="9007199254740994",modified=1234567890000)
        val hint = PdfSourceIdentity.from(uri,file)
        assertEquals("9007199254740994",PdfSourceIdentity.selected(uri,file.id,JSONObject(hint.toString()))!!.objectId)
        assertNull(PdfSourceIdentity.selected("cloud://other/Comics/book.pdf",file.id,hint))
        assertNull(PdfSourceIdentity.selected(uri,file.id,JSONObject().put("uri",uri).put("id","https://secret/ticket").put("size",3145925)))
        assertEquals(setOf("uri","id","size","modified"), hint.keys().asSequence().toSet())
        var lookups = 0
        val client = OpenListBackend.Client(mount,"quark_open",stream={error("must not play video")}) { _,route,body ->
            lookups++; assertEquals("/archive-stream",route);assertEquals(file.objectId,body!!.getString("id"))
            JSONObject().put("data",JSONObject().put("name",file.name).put("id",file.objectId).put("size",file.size).put("stream","http://127.0.0.1:1234/generic-archive/receipt/book.pdf"))
        }
        val reopened=client.findArchiveForPlayback(file.id,PdfSourceIdentity.selected(uri,file.id,hint))
        client.resolveArchive(reopened)
        assertEquals(1,lookups)
    }

    @Test fun missingDirectoryIdentityIsNotReportedAsANetworkOutage() {
        assertEquals("PDF_LOCATION_EXPIRED",PdfDocuments.safeError(CloudFailure("cloud_location_expired")))
        assertEquals("PDF_NETWORK_UNAVAILABLE",PdfDocuments.safeError(CloudFailure()))
    }

    @Test fun everyCurrentProviderPreservesPdfIdentityAndUsesOneBoundSourceForRepeatedReads() {
        val bytes = ByteArray(2 * PdfReadCache.BLOCK_BYTES + 197) { (it % 251).toByte() }
        for (provider in CloudDrive.PROVIDERS.keys) for (listed in listOf(false, true)) {
            assertTrue(provider, OpenListBackend.supported(provider))
            val requests = AtomicInteger(); var lookups = 0
            val server = CloudStreamSourceTest.HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
            server.createContext("/book.pdf") { exchange ->
                requests.incrementAndGet()
                assertEquals("1", exchange.requestHeaders.getFirst("X-Thru3D-Archive-Read"))
                val (start, end) = exchange.requestHeaders.getFirst("Range")!!.removePrefix("bytes=").split('-').map(String::toInt)
                exchange.responseHeaders.add("Content-Type", "application/pdf")
                exchange.responseHeaders.add("Content-Range", "bytes $start-$end/${bytes.size}")
                exchange.sendResponseHeaders(206, (end-start+1).toLong())
                exchange.responseBody.use { it.write(bytes,start,end-start+1) }; exchange.close()
            }
            server.start()
            try {
                val name = "漫画 #?%.PDF"; val path = "/Comics/$name"
                val url = "http://127.0.0.1:${server.address.port}/book.pdf"
                val id = if (provider == CloudDrive.OPEN115) "9007199254740994" else "object-pdf"
                val client = OpenListBackend.Client(mount, provider, "parent-id", stream = { error("PDF must not switch video playback") }) { method, route, body ->
                    lookups++
                    assertEquals("POST", method)
                    assertEquals(if (provider == CloudDrive.OPEN115) "/stat115" else "/archive-stream",route)
                    assertEquals(path,body!!.getString("path")); assertEquals(mount,body.getString("mount"))
                    assertEquals(if(listed) id else "",body.getString("id"))
                    val data = JSONObject().put("name",name).put("size",bytes.size).put("id",id).put("is_dir",false)
                    if(provider == CloudDrive.OPEN115) {
                        assertEquals("parent-id",body.getString("folder_id"))
                        JSONObject().put("data",data).put("stream",url)
                    } else JSONObject().put("data",data.put("stream",url))
                }
                val selected = if (listed) CloudFile(name,false,bytes.size.toLong(),path,objectId=id) else null
                val file = client.findArchiveForPlayback(path,selected)
                val row = CloudLibrary.directoryEntry("/account/Comics",file,client)!!
                assertEquals("pdf",row.getString("kind")); assertEquals(name,row.getString("title"))
                assertEquals("/account/Comics/$name",CloudPaths.path(row.getString("uri")))
                assertNull(CloudLibrary.directoryEntry("/account/Comics",file,client,true))
                val source = CloudStreamSource(file.size,{client.resolveArchive(file)},OpenListBackend::connection)
                    .boundedRanges(PdfReadCache.BLOCK_BYTES.toLong()).forPdfReading()
                source.prepare()
                PdfReadCache(PdfNetworkSource(source) {}, Files.createTempFile("pdf-provider", ".blocks").toFile()).use { cache ->
                    for (offset in listOf(0, bytes.size-100, 123, bytes.size-100)) {
                        val output = ByteArray(100)
                        assertEquals(100,cache.read(offset.toLong(),output,100))
                        assertArrayEquals(bytes.copyOfRange(offset,offset+100),output)
                    }
                }
                assertEquals("$provider listed=$listed lookups",1,lookups)
                assertEquals("$provider listed=$listed ranges",2,requests.get())
            } finally { server.stop(0) }
        }
    }

    @Test fun literalPdfNamesSurviveLegacy115ListingAndSearchWithoutLinkRequests() {
        var calls = 0
        val name = "漫画 #?%.PDF"
        val client = CloudDrive(CloudDrive.P115,"UID=fixture",CloudTransport { url,_,form ->
            calls++; assertNull(form); assertTrue(url.contains("/files?"))
            CloudResponse(JSONObject().put("state",true).put("count",1).put("data",org.json.JSONArray().put(
                JSONObject().put("fid","9007199254740994").put("n",name).put("s",3145925).put("pc","pdf-pick"))))
        })
        val file = client.page("/").files.single()
        val row = CloudLibrary.directoryEntry("/account",file,client)!!
        assertEquals("pdf",row.getString("kind")); assertEquals(name,row.getString("title"))
        val uri = CloudPaths.uri("/account/$name")
        assertEquals("/account/$name",CloudPaths.path(uri))
        val results = CloudDirectorySearch().search("account","identity",client,"/","漫画","all","",false).getJSONArray("content")
        assertEquals(name,results.getJSONObject(0).getString("name")); assertEquals(1,calls)
        assertFalse(MediaKinds.supportedFileName("book.pdf.exe"))
    }
}
