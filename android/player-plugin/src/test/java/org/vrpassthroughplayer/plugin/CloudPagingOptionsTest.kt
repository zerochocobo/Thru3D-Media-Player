package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CloudPagingOptionsTest {
    private val mount = "/12345678-1234-1234-1234-123456789abc"

    @Test fun groupingTravelsWithOrderAndCannotBypassProviderCapabilities() {
        for (provider in listOf(CloudDrive.OPEN115, CloudDrive.WEBDAV)) {
            var calls = 0
            val client = OpenListBackend.Client(mount, provider) { _, _, body ->
                calls++
                assertEquals("mixed_name_asc", body!!.getString("order"))
                JSONObject().put("data", JSONObject().put("total", 0).put("next_offset", -1).put("content", JSONArray()))
            }
            client.sizedPage("/", 0, false, "mixed_name_asc", 200)
            assertEquals(1, calls)
        }
        val client = OpenListBackend.Client(mount, CloudDrive.QUARK) { _, _, _ -> throw AssertionError("Unsupported grouping reached network") }
        assertThrows(IllegalArgumentException::class.java) { client.orderedPage("/", 0, false, "mixed_name_asc") }
    }

    @Test fun providerDefaultsReachNativeRequestsAndKeepRawRows() {
        for ((provider, size) in mapOf(CloudDrive.OPEN115 to 200, CloudDrive.BAIDU to 1000,
            CloudDrive.ALIYUN to 200, CloudDrive.QUARK to 100, CloudDrive.ONEDRIVE to 200, CloudDrive.WEBDAV to 200)) {
            var calls = 0
            val client = OpenListBackend.Client(mount, provider, "folder") { _, route, body ->
                calls++
                assertEquals(if (provider == CloudDrive.OPEN115) "/list115" else "/directory", route)
                assertEquals(size, body!!.getInt("page_size"))
                assertEquals(size * 527, body.getInt("offset"))
                val items = JSONArray()
                repeat(size) { i -> items.put(JSONObject().put("id", "id-$i").put("name", if (i == 0) "bad/name" else "$i.txt").put("is_dir", false)) }
                JSONObject().put("data", JSONObject().put("total", if (provider == CloudDrive.OPEN115) size * 600 else -1)
                    .put("next_offset", size * 528).put("content", items))
            }
            val page = client.sizedPage("/Movies", size * 527, false, "name_asc", 0)
            assertEquals(1, calls)
            assertEquals(size, page.pageSize)
            assertEquals(size, page.rawCount)
            assertEquals(size, page.rawIds.size)
            assertEquals(size - 1, page.files.size)
            assertEquals(size * 528, page.nextOffset)
        }
    }

    @Test fun unsupportedSizesAndMisalignedCursorsNeverReachNetwork() {
        val client = OpenListBackend.Client(mount, CloudDrive.QUARK) { _, _, _ -> error("Network must not run") }
        assertThrows(IllegalArgumentException::class.java) { client.sizedPage("/", 0, false, "name_asc", 200) }
        assertThrows(IllegalArgumentException::class.java) { client.sizedPage("/", 48, false, "name_asc", 100) }
        assertThrows(IllegalArgumentException::class.java) { client.sizedPage("/", 0, false, "name_asc", -1) }
        assertEquals(48, CloudDrive.PAGE_SIZE)
        assertFalse(CloudPaging.direct(CloudDrive.ALIYUN))
        assertTrue(CloudPaging.direct(CloudDrive.BAIDU))
    }

    @Test fun companionPagesRetainTheirLegacySizeAfterSizedBrowsing() {
        val sizes = ArrayList<Int>()
        val client = OpenListBackend.Client(mount, CloudDrive.ONEDRIVE) { _, _, body ->
            sizes.add(body!!.getInt("page_size"))
            JSONObject().put("data", JSONObject().put("total", -1).put("next_offset", -1).put("content", JSONArray()))
        }
        client.sizedPage("/", 0, false, "name_asc", 200)
        client.page("/", 0, false)
        assertEquals(listOf(200, 48), sizes)
    }
}
