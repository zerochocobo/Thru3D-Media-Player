package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test

class ArchiveUnlocksTest {
    @Test fun onlyVerifiedExactArchivesAreReusedAndSavingIsOptional() {
        var disk = JSONArray()
        fun vault() = ArchiveUnlocks({ JSONArray(disk.toString()) }, { disk = JSONArray(it.toString()) })
        val unlocks = vault()
        assertEquals("", unlocks.password("cloud://a/book.zip", setOf("unused")))
        unlocks.verified("cloud://a/book.zip", "visible password", false)
        assertEquals("visible password", unlocks.password("cloud://a/book.zip", emptySet()))
        assertEquals("", unlocks.password("cloud://b/book.zip", setOf("visible password")))
        assertEquals(0, disk.length())
        assertEquals("", vault().password("cloud://a/book.zip", setOf("visible password")))
        unlocks.verified("cloud://a/book.zip", "visible password", true)
        assertFalse(disk.toString().contains("cloud://a/book.zip"))
        assertEquals("visible password", vault().password("cloud://a/book.zip", setOf("visible password")))
        assertEquals("", vault().password("cloud://a/book.zip", emptySet()))
        unlocks.forget("visible password")
        assertEquals(0, disk.length())
        assertEquals("", unlocks.password("cloud://a/book.zip", setOf("visible password")))
    }

    @Test fun sessionSecretsAreBoundedAndDeletionRemovesAllAssociations() {
        var disk = JSONArray()
        val unlocks = ArchiveUnlocks({ disk }, { disk = it })
        for (i in 0..100) unlocks.verified("file:///book-$i.zip", "same", true)
        assertEquals(100, disk.length())
        assertEquals("", unlocks.password("file:///book-0.zip", setOf("same")))
        assertEquals("same", unlocks.password("file:///book-100.zip", emptySet()))
        unlocks.clear()
        assertEquals("", unlocks.password("file:///book-100.zip", emptySet()))
        unlocks.forget("same")
        assertEquals(0, disk.length())
    }
}
