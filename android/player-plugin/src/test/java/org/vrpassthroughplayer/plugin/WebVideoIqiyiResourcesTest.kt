package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebVideoIqiyiResourcesTest {
    private val first="https://declared.test/first.ts?start=0&end=188&contentlength=188&sd=0"
    private val tail="https://declared.test/tail.ts?start=0&end=376&contentlength=376&sd=0"
    private val manifest="#EXTM3U\n#EXTINF:2,\n$first\n#EXTINF:8,\n$tail\n#EXT-X-ENDLIST\n"
    private fun plan(): JSONObject {
        val files=JSONArray();val requests=JSONArray()
        for((index,id) in listOf("first","tail").withIndex()) {
            files.put(JSONObject().put("url","https://declared.test/$id.ts?issued=A%2bB%3D&qd_tvid=42").put("source_id",id).put("start",0).put("end",if(index==0)188 else 376))
            requests.put(JSONObject().put("url",if(index==0)first else tail).put("file",index).put("start",0).put("end",if(index==0)188 else 376))
        }
        return JSONObject().put("page","https://www.iqiyi.com/v_unit.html").put("tvid","42").put("ff","ts").put("files",files).put("requests",requests)
    }
    @Test fun lazilyDispatchesFutureFilesAndReusesOnlyTheSameFileResult() {
        val calls=ArrayList<URI>()
        val headers:(URI)->Map<String,String> = { mapOf("user-agent" to "unit","cookie" to "exact:${it.rawPath}") }
        val fetch:(URI,Map<String,String>,Boolean)->Pair<URI,ByteArray> = { uri,h,prefix ->
            calls.add(uri);assertFalse(prefix);assertEquals(headers(uri),h)
            assertTrue(uri.rawQuery.startsWith("issued=A%2bB%3D&qd_tvid=42&pv=0.1&cross-domain=1&mss=3"))
            val body=JSONObject().put("uri",uri.rawPath).put("d",JSONArray().put(JSONObject().put("URL","https://new-associated-cdn.test${uri.rawPath}?key=FILE%2bKEY%3D&qd_tvid=42")))
            uri to body.toString().toByteArray()
        }
        WebVideoIqiyiResources(plan(),manifest).use { resources ->
            assertTrue(calls.isEmpty())
            val one=resources.target(URI(first),headers,fetch)
            assertEquals("https://new-associated-cdn.test/first.ts?key=FILE%2bKEY%3D&qd_tvid=42&start=0&end=188&contentlength=188",one.toString())
            assertEquals(one,resources.target(URI(first),headers,fetch));assertEquals(1,calls.size)
            assertTrue(resources.target(URI(tail),headers,fetch).rawPath.endsWith("/tail.ts"));assertEquals(2,calls.size)
            resources.close();assertThrows(IllegalStateException::class.java) { resources.target(URI(first),headers,fetch) };assertEquals(2,calls.size)
        }
    }
    @Test fun aDispatcherCannotSubstituteAnotherFileOrProgrammeAndErrorsHidePrivateResponseValues() {
        for(body in listOf("{PRIVATE_BAD_JSON", "{\"uri\":\"/other.ts\",\"d\":[]}",
            "{\"uri\":\"/first.ts\",\"d\":[{\"URL\":\"https://cdn.test/first.ts?qd_tvid=43&key=PRIVATE\"}]}",
            "{\"uri\":\"/first.ts\",\"d\":[{\"URL\":\"file:///PRIVATE\"}]}")) {
            WebVideoIqiyiResources(plan(),manifest).use { resources ->
                val error=assertThrows(IllegalStateException::class.java) { resources.target(URI(first),{emptyMap()}) { uri,_,_ -> uri to body.toByteArray() } }
                assertFalse(error.toString().contains("PRIVATE"));assertNull(error.cause)
            }
        }
    }
    @Test fun requestsMustBelongToTheCompleteManifestAndDeclaredFileBounds() {
        val m=plan();m.getJSONArray("requests").getJSONObject(1).put("file",0)
        assertThrows(Exception::class.java) { WebVideoIqiyiResources(m,manifest) }
        assertThrows(Exception::class.java) { WebVideoIqiyiResources(plan(),manifest.replace(tail,tail+"&other=resource")) }
    }
    @Test fun byteSelectorsLeaveAllOtherRawSignatureParametersUntouched() {
        val uri=URI("https://cdn.test/file.ts?key=A%2bB%3D&start=0&end=188&contentlength=188&qd_tvid=42")
        assertEquals("https://cdn.test/file.ts?key=A%2bB%3D&start=188&end=752&contentlength=564&qd_tvid=42",WebVideoIqiyiResources.rangeUrl(uri,188,752).toString())
        assertThrows(Exception::class.java) { WebVideoIqiyiResources.rangeUrl(URI(uri.toString()+"&start=1"),0,188) }
    }
}
