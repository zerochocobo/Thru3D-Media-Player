package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class PdfDocumentsTest {
    @Test fun coldOpenPassesSavedHintAndEmitsVerifiedIdentityForHistory() {
        val results = LinkedBlockingQueue<String>()
        val hint = JSONObject().put("uri","cloud://account/book.pdf").put("id","saved-id").put("size",120)
        val docs = PdfDocuments({ _, _, input ->
            assertEquals(hint.toString(),input.toString())
            object : PdfDocuments.Renderer {
                override val pages=1
                override val sourceIdentity=JSONObject(hint.toString()).put("modified",1234)
                override fun render(page:Int,edge:Int):File = error("directory must not render")
                override fun close() {}
            }
        }) { _, payload -> results.add(payload) }
        try {
            docs.open(23,"cloud://account/book.pdf",hint.toString())
            val ready=JSONObject(results.poll(3,TimeUnit.SECONDS)!!)
            assertEquals("ready",ready.getString("state"))
            assertEquals(1234,ready.getJSONObject("source_file").getInt("modified"))
        } finally { docs.close() }
    }
    @Test fun lastCloudConsumerCancelsBlockedPageReadWithoutWaitingForRendererClose() {
        val ready = CountDownLatch(1); val reading = CountDownLatch(1)
        val cancelled = CountDownLatch(1); val closed = CountDownLatch(1)
        val docs = PdfDocuments({ source, cancellation, _ ->
            assertEquals("cloud://account/book.pdf", source)
            cancellation.attachAction { cancelled.countDown() }
            object : PdfDocuments.Renderer {
                override val pages = 3
                override fun render(page: Int, edge: Int): File {
                    reading.countDown()
                    check(cancelled.await(3, TimeUnit.SECONDS))
                    throw CloudFailure()
                }
                override fun close() { closed.countDown() }
            }
        }) { _, _ -> ready.countDown() }
        val reader = java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            docs.open(21, "cloud://account/book.pdf"); assertTrue(ready.await(3, TimeUnit.SECONDS))
            assertTrue(docs.retain("21")); docs.release("21")
            assertEquals(1L, cancelled.count)
            val result = reader.submit<String> { docs.resolve("pdfpage://21/1", 2048) }
            assertTrue(reading.await(3, TimeUnit.SECONDS))
            docs.release("21")
            assertTrue(cancelled.await(1, TimeUnit.SECONDS))
            assertThrows(java.util.concurrent.ExecutionException::class.java) { result.get(3, TimeUnit.SECONDS) }
            assertTrue(closed.await(3, TimeUnit.SECONDS))
            assertFalse(docs.retain("21"))
        } finally { docs.close(); reader.shutdownNow() }
    }

    @Test fun cancellingCloudOpenInterruptsTransportBeforeRendererExists() {
        val entered = CountDownLatch(1); val cancelled = CountDownLatch(1)
        val events = AtomicInteger(); val finished = CountDownLatch(1)
        val docs = PdfDocuments({ _, cancellation, _ ->
            cancellation.attachAction { cancelled.countDown() }; entered.countDown()
            try { check(cancelled.await(3, TimeUnit.SECONDS)); throw CloudFailure() }
            finally { finished.countDown() }
        }) { _, _ -> events.incrementAndGet() }
        try {
            docs.open(22, "cloud://account/book.pdf"); assertTrue(entered.await(3, TimeUnit.SECONDS))
            docs.release("22"); assertTrue(finished.await(1, TimeUnit.SECONDS)); assertEquals(0, events.get())
        } finally { docs.close() }
    }

    private class Sheet(override val pages: Int = 3) : PdfDocuments.Renderer {
        val renders = mutableListOf<Pair<Int, Int>>()
        val closed = CountDownLatch(1)
        override fun render(page: Int, edge: Int): File { renders.add(page to edge); return File("page-$page.png") }
        override fun close() { closed.countDown() }
    }
    @Test fun smbLiteralNamesReachRendererWithoutStrictUriParsingOrDecoding() {
        val results = LinkedBlockingQueue<String>(); val opened = mutableListOf<String>()
        val docs = PdfDocuments({ uri, _, _ -> opened.add(uri); Sheet() }) { _, result -> results.add(result) }
        try {
            val names = listOf("サイトウ零央.pdf", "[weiphone][PDF电子书][龙珠]Vol.02.pdf", "Book #?%2F 01.pdf")
            names.forEachIndexed { index, name ->
                val uri = "smb://saved-server/VRRecommend/TEST/$name"
                docs.open(index, uri)
                assertEquals("ready", JSONObject(results.poll(3, TimeUnit.SECONDS)!!).getString("state"))
                assertEquals(uri, opened.last()); docs.release(index.toString())
            }
            listOf("smb://saved-server", "smb://saved-server/share/../book.pdf", "smb://saved-server//book.pdf").forEachIndexed { index, uri ->
                docs.open(index + 10, uri)
                assertEquals("PDF_UNAVAILABLE", JSONObject(results.poll(3, TimeUnit.SECONDS)!!).getString("error"))
                docs.release((index + 10).toString())
            }
            assertEquals(3, opened.size)
        } finally { docs.close() }
    }
    @Test fun obsoleteQueuedPrefetchNeverRendersOrClosesTheSharedDocument() {
        val sheet = Sheet(); val ready = CountDownLatch(1)
        val docs = PdfDocuments({ _, _, _ -> sheet }) { _, _ -> ready.countDown() }
        try {
            docs.open(18, "file:///book.pdf"); assertTrue(ready.await(3, TimeUnit.SECONDS))
            assertThrows(Exception::class.java) { docs.resolve("pdfpage://18/1", 3072) { true } }
            assertTrue(sheet.renders.isEmpty())
            docs.validate("pdfpage://18/0")
            docs.resolve("pdfpage://18/0", 3072)
            assertEquals(listOf(0 to 3072), sheet.renders)
            docs.release("18"); assertTrue(sheet.closed.await(3, TimeUnit.SECONDS))
            assertThrows(Exception::class.java) { docs.validate("pdfpage://18/0") }
        } finally { docs.close() }
    }
    @Test fun directoryDoesNotRasterizeAndIndependentWindowsKeepDocumentAlive() {
        val sheet = Sheet(); val results = LinkedBlockingQueue<String>()
        val docs = PdfDocuments({ _, _, _ -> sheet }) { _, result -> results.add(result) }
        try {
            assertEquals(17, docs.open(17, "file:///book.pdf"))
            val ready = JSONObject(results.poll(3, TimeUnit.SECONDS)!!)
            assertEquals("ready", ready.getString("state")); assertEquals(3, ready.getJSONArray("entries").length())
            assertTrue(sheet.renders.isEmpty())
            assertTrue(docs.retain("17")); assertTrue(docs.retain("17"))
            docs.release("17") // Browser closes while two windows keep reading.
            assertTrue(docs.resolve("pdfpage://17/2", 2048).endsWith("page-2.png"))
            docs.release("17")
            docs.resolve("pdfpage://17/0", 99999)
            assertEquals(listOf(2 to 2048, 0 to 3072), sheet.renders)
            assertEquals(1L, sheet.closed.count)
            docs.release("17"); assertTrue(sheet.closed.await(3, TimeUnit.SECONDS))
            assertFalse(docs.retain("17"))
            assertThrows(Exception::class.java) { docs.resolve("pdfpage://17/0", 2048) }
        } finally { docs.close() }
    }
    @Test fun cancellingSlowOpenSuppressesDeliveryAndClosesRenderer() {
        val entered = CountDownLatch(1); val resume = CountDownLatch(1); val sheet = Sheet()
        val events = AtomicInteger()
        val docs = PdfDocuments({ _, _, _ -> entered.countDown(); resume.await(); sheet }) { _, _ -> events.incrementAndGet() }
        try {
            docs.open(1, "content://com.android.externalstorage.documents/book.pdf")
            assertTrue(entered.await(3, TimeUnit.SECONDS)); docs.release("1"); resume.countDown()
            assertTrue(sheet.closed.await(3, TimeUnit.SECONDS)); assertEquals(0, events.get())
        } finally { resume.countDown(); docs.close() }
    }
    @Test fun remoteEncryptedAndOversizedDocumentsHaveBoundedErrors() {
        val results = LinkedBlockingQueue<String>(); val opens = AtomicInteger()
        val docs = PdfDocuments({ source, _, _ -> opens.incrementAndGet(); if (source.endsWith("locked.pdf")) throw IllegalArgumentException("PDF_PASSWORD_UNSUPPORTED") else if (source.endsWith("denied.pdf")) throw SecurityException("secret") else Sheet(20001) }) { _, result -> results.add(result) }
        try {
            for ((id, uri, error) in listOf(Triple(1,"https://example.org/book.pdf","PDF_UNAVAILABLE"),
                Triple(2,"file:///locked.pdf","PDF_PASSWORD_UNSUPPORTED"), Triple(3,"file:///big.pdf","PDF_PAGE_LIMIT"), Triple(4,"content://provider/denied.pdf","PDF_UNAVAILABLE"))) {
                docs.open(id, uri)
                val result = JSONObject(results.poll(3, TimeUnit.SECONDS)!!)
                assertEquals(error, result.getString("error")); assertFalse(result.toString().contains("secret")); docs.release(id.toString())
            }
            assertEquals(3, opens.get())
        } finally { docs.close() }
    }
    @Test fun failedAndOutOfRangeReadsDoNotStealBrowserReference() {
        val ready = CountDownLatch(1); val sheet = Sheet()
        val docs = PdfDocuments({ _, _, _ -> sheet }) { _, _ -> ready.countDown() }
        try {
            docs.open(5,"file:///book.pdf"); assertTrue(ready.await(3,TimeUnit.SECONDS))
            for (uri in listOf("pdfpage://5/-1","pdfpage://5/3","pdfpage://5/0?token=bad","pdfpage://other/0"))
                assertThrows(Exception::class.java) { docs.resolve(uri,2048) }
            assertTrue(docs.resolve("pdfpage://5/1",2048).endsWith("page-1.png"))
            docs.release("5"); assertTrue(sheet.closed.await(3,TimeUnit.SECONDS))
        } finally { docs.close() }
    }
    @Test fun pdfIsADocumentNotAVideoOrCompressedArchive() {
        assertTrue(MediaKinds.supported("Book.PDF")); assertEquals("pdf",MediaKinds.kind("Book.PDF"))
        assertTrue(MediaKinds.supportedFileName("Book #1?.PDF")); assertEquals("pdf",MediaKinds.fileNameKind("Book #1?.PDF"))
        assertFalse(ArchiveKinds.supported("book.pdf")); assertFalse(MediaKinds.image("book.pdf"))
        assertFalse(MediaKinds.supported("book.pdf.exe"))
    }
}
