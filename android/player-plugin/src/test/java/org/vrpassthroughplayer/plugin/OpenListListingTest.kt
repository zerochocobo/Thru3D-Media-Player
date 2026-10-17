package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class OpenListListingTest {
    private val mount = "/12345678-1234-1234-1234-123456789abc"
    @Test fun known115FolderIdReachesFirstPageNextPageSortAndRefreshWithoutStat() {
        val calls = ArrayList<Pair<Int, Boolean>>()
        val client = OpenListBackend.Client(mount, CloudDrive.OPEN115, "9007199254740993") { _, route, body ->
            assertEquals("/list115", route)
            assertEquals("9007199254740993", body!!.getString("folder_id"))
            assertEquals("/电影/3D/合集", body.getString("path"))
            calls.add(body.getInt("offset") to body.getBoolean("refresh"))
            JSONObject().put("data", JSONObject().put("total", 8000).put("content", JSONArray().put(JSONObject()
                .put("id", "1").put("name", "movie.mp4").put("is_dir", false).put("size", 12))))
        }
        val pages = CloudSortedPages()
        for (order in CloudSortedPages.ORDERS + "source") {
            pages.page(client, "/电影/3D/合集", 0, false, order)
            pages.page(client, "/电影/3D/合集", 48, false, order)
            pages.page(client, "/电影/3D/合集", 0, true, order)
        }
        assertEquals(21, calls.size)
        assertEquals(listOf(0 to false, 48 to false, 0 to true), calls.take(3))
    }
    @Test fun everyOtherProviderUsesNativePagesWithoutGatheringTheDirectoryForSort() {
        for (provider in listOf(CloudDrive.BAIDU, CloudDrive.ALIYUN, CloudDrive.QUARK, CloudDrive.ONEDRIVE, CloudDrive.WEBDAV)) {
            for (order in CloudSortedPages.ORDERS + "source") {
                if (provider == CloudDrive.QUARK && order.startsWith("size_")) continue
                val calls = ArrayList<Int>()
                val client = OpenListBackend.Client(mount, provider, "folder-id") { _, route, body ->
                    assertEquals("/directory", route)
                    assertEquals(mount, body!!.getString("mount"))
                    assertEquals("/Movies", body.getString("path"))
                    assertEquals("folder-id", body.getString("folder_id"))
                    assertEquals(order, body.getString("order"))
                    val offset = body.getInt("offset"); calls.add(offset)
                    val rows = JSONArray()
                    if (offset != 48) rows.put(JSONObject().put("id", "$offset").put("name", "movie$offset.mp4")
                        .put("is_dir", false).put("size", 90000000000L).put("modified_ms", 42))
                    JSONObject().put("data", JSONObject().put("content", rows).put("total", -1).put("next_offset", if (offset < 96) offset + 48 else -1))
                }
                val pages = CloudSortedPages()
                val first = pages.page(client, "/Movies", 0, false, order)
                assertEquals(listOf(0), calls)
                assertEquals(-1, first.total)
                assertEquals("0", first.files.single().objectId)
                assertEquals(48, first.nextOffset)
                assertEquals(96, pages.page(client, "/Movies", 48, false, order).nextOffset)
                assertEquals(-1, pages.page(client, "/Movies", 96, false, order).nextOffset)
                assertEquals(listOf(0, 48, 96), calls)
            }
        }
    }

    @Test fun quarkUnsupportedSizeOrderMigratesToNameWithoutLocalMetadataSort() {
        assertEquals("name_asc", CloudLibrary.effectiveOrder(CloudDrive.QUARK, "size_desc"))
        assertEquals("modified_desc", CloudLibrary.effectiveOrder(CloudDrive.QUARK, "modified_desc"))
        val orders = CloudLibrary.sortOrders(CloudDrive.QUARK)
        assertEquals(5, orders.length())
        assertFalse(orders.toString().contains("size_"))
        assertEquals(7, CloudLibrary.sortOrders(CloudDrive.ONEDRIVE).length())
    }
    private fun client(names: List<String>, ids: List<String> = names.indices.map { "${9007199254740993L + it}" }): CloudClient = OpenListBackend.Client(mount, CloudDrive.OPEN115) { method, route, body ->
        assertEquals("POST", method)
        assertEquals(mount, body!!.getString("mount"))
        fun item(i: Int) = JSONObject().put("name", names[i]).put("id", ids[i]).put("is_dir", false)
            .put("size", 12).put("modified_ms", 10).put("can_delete", true)
        if (route == "/stat115") {
            val matches = names.indices.filter { names[it] == body.getString("path").substringAfterLast('/') }
            if (matches.size > 1) throw CloudFailure("cloud_file_ambiguous")
            if (matches.isEmpty()) throw CloudFailure("cloud_file_missing")
            JSONObject().put("code", 200).put("data", item(matches.single()))
        } else {
            assertEquals("/list115", route)
            val offset = body.getInt("offset")
            val items = JSONArray()
            for (i in offset until minOf(offset + CloudDrive.PAGE_SIZE, names.size)) items.put(item(i))
            JSONObject().put("code", 200).put("data", JSONObject().put("total", names.size).put("content", items))
        }
    }

    @Test fun similarNamesAndBothParenthesisWidthsSurviveListingSortingAndUris() {
        val names = listOf("test.mp4", "test(2).mp4", "test（2）.mp4", "test (2).mp4", "test[2].mp4", "test.srt", "q.mp4")
        val client = client(names)
        assertEquals(names, client.list("/").map { it.name })
        for (order in CloudSortedPages.ORDERS + "source") {
            val files = CloudSortedPages().page(client, "/", 0, false, order).files
            assertEquals(names.filter { it != "test.srt" }.toSet(), files.filter { MediaKinds.supported(it.name) }.map { it.name }.toSet())
            for (file in files) {
                val path = mount + file.id
                assertEquals(path, CloudPaths.path(CloudPaths.uri(path)))
                assertEquals(file.objectId, client.find(file.id).objectId)
            }
        }
    }

    @Test fun exactDuplicateNamesDoNotHideOtherFilesButCannotResolveAnAmbiguousPath() {
        val client = client(listOf("test.mp4", "test.mp4", "test(2).mp4", "q.mp4"))
        assertEquals(4, client.page("/").files.size)
        val files = CloudSortedPages().page(client, "/", 0, false, "name_asc").files
        assertEquals(4, files.size)
        assertEquals(4, files.map { it.objectId }.toSet().size)
        assertEquals("q.mp4", client.find("/q.mp4").name)
        assertEquals("cloud_file_ambiguous", assertThrows(CloudFailure::class.java) { client.find("/test.mp4") }.reason)
        assertThrows(CloudFailure::class.java) { client.resolve(files.first { it.name == "test.mp4" }) }
    }

    @Test fun duplicateNamesAcrossRequestedPagesRemainVisibleAndRejectAmbiguousPlayback() {
        val names = (0 until 55).map { if (it == 0 || it == 54) "test.mp4" else "test($it).mp4" }
        val client = client(names)
        assertEquals(names, client.list("/").map { it.name })
        val pages = CloudSortedPages()
        val first = pages.page(client, "/", 0, false, "name_asc")
        val second = pages.page(client, "/", 48, false, "name_asc")
        assertEquals(55, first.total)
        assertEquals(55, (first.files + second.files).map { it.objectId }.toSet().size)
        assertThrows(CloudFailure::class.java) { client.find("/test.mp4") }
    }

    @Test fun repeatedObjectIdsStillRejectInvalidProviderPages() {
        val repeated = client(listOf("test.mp4", "test(2).mp4"), listOf("1", "1"))
        assertThrows(CloudFailure::class.java) { repeated.page("/") }
        val names = (0 until 55).map { "test($it).mp4" }
        val ids = names.indices.map { if (it == 54) "1" else "${it + 1}" }
        assertThrows(CloudFailure::class.java) { client(names, ids).list("/") }
        assertEquals(48, CloudSortedPages().page(client(names, ids), "/", 0, false, "name_asc").files.size) // Later pages are not fetched eagerly.
    }

    @Test fun ambiguousSidecarPathsAreRejectedBeforePublishingAnyStream() {
        val client = client(listOf("movie.mp4", "movie.srt", "movie.srt", "movie.si.mix.m4a", "movie.si.mix.m4a"))
        var published = 0
        assertTrue(SidecarSubtitles.forCloud("/movie.mp4", client.page("/").files) { published++; "unexpected" }.isEmpty())
        assertTrue(SidecarAudio.forCloud("/movie.mp4", client.page("/").files) { published++; "unexpected" }.isEmpty())
        assertEquals(0, published)
        assertEquals("movie.mp4", client.find("/movie.mp4").name)
    }

    @Test fun largeFolderAndEverySortRequestOnlyTheRequestedProviderPage() {
        for (total in listOf(8000, 50000)) for (order in CloudSortedPages.ORDERS + "source") {
            val offsets = ArrayList<Int>()
            val client = OpenListBackend.Client(mount, CloudDrive.OPEN115) { _, route, body ->
                assertEquals("/list115", route)
                assertEquals("/3D大片合集原盘", body!!.getString("path"))
                assertEquals(order, body.getString("order"))
                offsets.add(body.getInt("offset"))
                val rows = JSONArray()
                repeat(48) { rows.put(JSONObject().put("id", "${offsets.last() + it + 1}")
                    .put("name", "3D${offsets.last() + it}.mp4").put("is_dir", false).put("size", 90000000000L)) }
                JSONObject().put("data", JSONObject().put("content", rows).put("total", total))
            }
            val pages = CloudSortedPages()
            assertEquals(total, pages.page(client, "/3D大片合集原盘", 0, false, order).total)
            assertEquals(listOf(0), offsets)
            assertEquals(48, pages.page(client, "/3D大片合集原盘", 48, false, order).files.size)
            assertEquals(listOf(0, 48), offsets)
        }
    }

    @Test fun shortProviderPageAndUnavailableNamesAdvanceByRawRowsWithoutFailingTheFolder() {
        val offsets = ArrayList<Int>()
        val client = OpenListBackend.Client(mount, CloudDrive.OPEN115) { _, _, body ->
            val offset = body!!.getInt("offset"); offsets.add(offset)
            val names = if (offset == 0) listOf("bad/name.mp4", "good.mp4") else listOf("last.mp4")
            val rows = JSONArray()
            names.forEachIndexed { i, name -> rows.put(JSONObject().put("id", "${offset+i+1}")
                .put("name", name).put("is_dir", false).put("size", 12)) }
            JSONObject().put("data", JSONObject().put("content", rows).put("total", 3))
        }
        val pages = CloudSortedPages()
        val first = pages.page(client, "/", 0, false, "name_asc")
        assertEquals(listOf("good.mp4"), first.files.map { it.name })
        assertEquals(2, first.nextOffset)
        assertEquals(-1, pages.page(client, "/", 2, false, "name_asc").nextOffset)
        assertEquals(listOf(0, 2), offsets)
        for (name in listOf("", ".", "..", "bad/name.mp4", "bad\\name.mp4", "bad\u0000name.mp4"))
            assertFalse(CloudPaths.validName(name))
    }
}
