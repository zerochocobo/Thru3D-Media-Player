package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.security.MessageDigest

class NarrationModelsTest {
    @get:Rule val temporary=TemporaryFolder()
    private val bytes="verified model bytes".toByteArray()
    private fun manifest(name: String="model/weights.data") = JSONObject().put(name,JSONObject()
        .put("bytes",bytes.size).put("sha256",MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {"%02x".format(it)}))
    @Test fun freshInstallAndReuseNeverDependOnExternalProvisioning() {
        val root=temporary.newFolder("fresh");var opened=0;var verified=0L
        repeat(2) {
            NarrationModels.ensure(root,manifest(),{opened++;ByteArrayInputStream(bytes)},{true},{verified+=it})
            assertArrayEquals(bytes,root.resolve("model/weights.data").readBytes())
        }
        assertEquals(1,opened);assertEquals((bytes.size*2).toLong(),verified)
    }
    @Test fun corruptExistingPayloadIsReplacedOnlyAfterBundledDigestMatches() {
        val root=temporary.newFolder("repair");val file=root.resolve("model/weights.data");file.parentFile!!.mkdirs()
        val old=ByteArray(bytes.size){42};file.writeBytes(old)
        assertThrows(IllegalArgumentException::class.java) {
            NarrationModels.ensure(root,manifest(),{ByteArrayInputStream(old)},{true},{fail("Invalid payload reported verified")})
        }
        assertArrayEquals(old,file.readBytes());assertEquals(listOf("weights.data"),file.parentFile!!.list()!!.toList())
        NarrationModels.ensure(root,manifest(),{ByteArrayInputStream(bytes)},{true},{})
        assertArrayEquals(bytes,file.readBytes())
    }
    @Test fun cancellationCleansPartialAssetAndKeepsExistingModel() {
        val root=temporary.newFolder("cancel");val file=root.resolve("model/weights.data");file.parentFile!!.mkdirs()
        val old=ByteArray(bytes.size){42};file.writeBytes(old);var active=true
        assertThrows(IllegalStateException::class.java) {
            NarrationModels.ensure(root,manifest(),{active=false;ByteArrayInputStream(bytes)},{active},{fail("Cancelled install reported verified")})
        }
        assertArrayEquals(old,file.readBytes());assertEquals(listOf("weights.data"),file.parentFile!!.list()!!.toList())
    }
    @Test fun unsafePathsAndMissingAssetsFailWithoutPublishingAPartialFile() {
        for(name in listOf("../escape","/absolute","folder/../escape","folder\\escape","C:escape")) {
            assertThrows(IllegalArgumentException::class.java) {
                NarrationModels.ensure(temporary.newFolder(),manifest(name),{ByteArrayInputStream(bytes)},{true},{})
            }
        }
        val root=temporary.newFolder("missing")
        assertThrows(java.io.FileNotFoundException::class.java) {
            NarrationModels.ensure(root,manifest(),{throw java.io.FileNotFoundException()},{true},{})
        }
        assertTrue(root.walkTopDown().none {it.isFile})
    }
}
