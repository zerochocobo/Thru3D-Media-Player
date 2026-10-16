package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class FavoritesVaultTest {
    private fun target() = Files.createTempDirectory("favorite-vault-").resolve("favorites.vault").toFile()

    @Test fun fourDigitsIncludeLeadingZeroAndRejectOtherForms() {
        val file = target()
        try {
            val vault = FavoritesVault(); vault.create(file.path, "0123", "leading zero")
            assertEquals("leading zero", FavoritesVault().open(file.path, "0123"))
            for (bad in listOf("123", "12345", "abcd", "１２３４")) {
                assertThrows(IllegalArgumentException::class.java) { vault.create(file.path, bad, "replacement") }
            }
            assertEquals("leading zero", FavoritesVault().open(file.path, "0123"))
        } finally { file.parentFile!!.deleteRecursively() }
    }

    @Test fun restartRequiresPasswordAndCiphertextDoesNotExposeMedia() {
        val file = target()
        try {
            val vault = FavoritesVault()
            val text = "{\"entries\":{\"title\":\"PRIVATE_MOVIE\",\"uri\":\"smb://private/file.mp4\"}}"
            vault.create(file.path, "1234", text)
            assertFalse(file.readText(Charsets.ISO_8859_1).contains("PRIVATE_MOVIE"))
            vault.lock()
            assertThrows(IllegalStateException::class.java) { vault.save(file.path, text) }
            assertEquals(text, FavoritesVault().open(file.path, "1234"))
        } finally { file.parentFile!!.deleteRecursively() }
    }

    @Test fun wrongPasswordAndTamperingNeverReplaceValidData() {
        val file = target()
        try {
            val vault = FavoritesVault(); vault.create(file.path, "1234", "first")
            val original = file.readBytes()
            assertThrows(IllegalArgumentException::class.java) { FavoritesVault().open(file.path, "9999") }
            assertArrayEquals(original, file.readBytes())
            val damaged = original.copyOf(); damaged[damaged.lastIndex] = (damaged.last().toInt() xor 1).toByte(); file.writeBytes(damaged)
            assertThrows(IllegalArgumentException::class.java) { FavoritesVault().open(file.path, "1234") }
            file.writeBytes(original); assertEquals("first", FavoritesVault().open(file.path, "1234"))
        } finally { file.parentFile!!.deleteRecursively() }
    }

    @Test fun everySaveUsesFreshNonceAndPasswordChangeRetainsPayload() {
        val file = target()
        try {
            val vault = FavoritesVault(); vault.create(file.path, "1234", "first")
            val old = file.readBytes(); vault.save(file.path, "first")
            assertFalse(old.contentEquals(file.readBytes()))
            vault.create(file.path, "5678", "updated"); vault.lock()
            assertThrows(IllegalArgumentException::class.java) { vault.open(file.path, "1234") }
            assertEquals("updated", vault.open(file.path, "5678"))
            assertFalse(java.io.File(file.path + ".tmp").exists())
        } finally { file.parentFile!!.deleteRecursively() }
    }

    @Test fun lockedOrShortPasswordCannotOverwriteExistingVault() {
        val file = target()
        try {
            val vault = FavoritesVault(); vault.create(file.path, "1234", "first")
            val original = file.readBytes(); vault.lock()
            assertThrows(IllegalStateException::class.java) { vault.create(file.path, "5678", "replacement") }
            assertThrows(IllegalArgumentException::class.java) { FavoritesVault().create(file.parentFile!!.resolve("short").path, "123", "bad") }
            assertArrayEquals(original, file.readBytes())
        } finally { file.parentFile!!.deleteRecursively() }
    }
}
