package org.vrpassthroughplayer.plugin

import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/** Password-derived, authenticated storage. No password or decrypted backup is written to disk. */
internal class FavoritesVault {
    private var key: ByteArray? = null
    private var salt: ByteArray? = null
    private var activePath: String? = null
    private var failures = 0
    private var retryAt = 0L
    private val random = SecureRandom()

    companion object {
        private const val ITERATIONS = 210_000
        private const val MAX_BYTES = 8 * 1024 * 1024
        private val MAGIC = byteArrayOf(0x54, 0x33, 0x46, 0x56, 1)
    }

    private fun derive(password: String, salt: ByteArray): ByteArray {
        require(password.length == 4 && password.all { it in '0'..'9' }) { "Use a 4-digit PIN" }
        val spec = PBEKeySpec(password.toCharArray(), salt, ITERATIONS, 256)
        return try { SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded }
        finally { spec.clearPassword() }
    }

    @Synchronized fun open(path: String, password: String): String {
        check(System.nanoTime() >= retryAt) { "Try again shortly" }
        try {
            val file = File(path)
            require(file.length() in 53..(MAX_BYTES + 128).toLong())
            val bytes = file.readBytes()
            val header = bytes.copyOfRange(0, 37)
            require(header.copyOfRange(0, 5).contentEquals(MAGIC))
            require(ByteBuffer.wrap(header, 5, 4).int == ITERATIONS)
            val newSalt = header.copyOfRange(9, 25)
            val proposed = derive(password, newSalt)
            try {
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(proposed, "AES"), GCMParameterSpec(128, header.copyOfRange(25, 37)))
                cipher.updateAAD(header)
                val text = cipher.doFinal(bytes.copyOfRange(37, bytes.size)).toString(Charsets.UTF_8)
                lock(); key = proposed.copyOf(); salt = newSalt; activePath = file.canonicalPath
                failures = 0; retryAt = 0
                return text
            } finally { proposed.fill(0) }
        } catch (error: Exception) {
            failures++
            if (failures >= 3) retryAt = System.nanoTime() + minOf(30, failures * 2) * 1_000_000_000L
            throw IllegalArgumentException("Incorrect password or damaged favorites")
        }
    }

    @Synchronized fun create(path: String, password: String, payload: String): String {
        val file = File(path)
        check(!file.exists() || (key != null && activePath == file.canonicalPath)) { "Unlock favorites first" }
        val newSalt = ByteArray(16).also(random::nextBytes)
        val proposed = derive(password, newSalt)
        try {
            write(file, proposed, newSalt, payload)
            lock(); key = proposed.copyOf(); salt = newSalt; activePath = file.canonicalPath
            return payload
        } finally { proposed.fill(0) }
    }

    @Synchronized fun save(path: String, payload: String): Boolean {
        check(activePath == File(path).canonicalPath) { "Unlock favorites first" }
        write(File(path), key ?: error("Unlock favorites first"), salt ?: error("Unlock favorites first"), payload)
        return true
    }

    private fun write(file: File, secret: ByteArray, salt: ByteArray, payload: String) {
        val text = payload.toByteArray(Charsets.UTF_8)
        require(text.size <= MAX_BYTES)
        val nonce = ByteArray(12).also(random::nextBytes)
        val header = ByteBuffer.allocate(37).put(MAGIC).putInt(ITERATIONS).put(salt).put(nonce).array()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(secret, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(header)
        val ciphertext = cipher.doFinal(text)
        check(file.parentFile?.let { it.isDirectory || it.mkdirs() } == true)
        val staged = File(file.path + ".tmp")
        try {
            FileOutputStream(staged).use { it.write(header); it.write(ciphertext); it.fd.sync() }
            Files.move(staged.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally { staged.delete(); text.fill(0) }
    }

    @Synchronized fun lock() { key?.fill(0); key = null; salt = null; activePath = null }
}
