package org.vrpassthroughplayer.plugin

import java.io.File
import java.io.InputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID

/** Transactional private copies, independent of a remote account's lifetime. */
internal object BackgroundAudioFiles {
    const val MAX_BYTES = 512L * 1024 * 1024
    val extensions = setOf("mp3", "ogg", "wav", "flac", "dts", "dtshd")
    data class Saved(val id: String, val file: File, val bytes: Long, val created: Boolean)

    fun copy(input: InputStream, directory: File, extension: String, expected: Long = -1,
             cancelled: () -> Boolean = { false }, progress: (Long, Long) -> Unit = { _, _ -> },
             validate: (File) -> Boolean = { true }): Saved {
        require(extension in extensions)
        require(expected <= MAX_BYTES) { "Audio file is empty or larger than 512 MB" }
        check(directory.isDirectory || directory.mkdirs()) { "Not enough space to save audio" }
        check(directory.usableSpace >= maxOf(1024 * 1024, expected.coerceAtLeast(0)) + 4 * 1024 * 1024) { "Not enough space to save audio" }
        val partial = File(directory, "${UUID.randomUUID()}.part")
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            partial.outputStream().use { output ->
                val buffer = ByteArray(65536)
                while (true) {
                    if (cancelled() || Thread.currentThread().isInterrupted) throw IOException("AUDIO_CANCELLED")
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count == 0) continue
                    total += count
                    require(total <= MAX_BYTES) { "Audio file is empty or larger than 512 MB" }
                    output.write(buffer, 0, count); digest.update(buffer, 0, count)
                    progress(total, expected)
                }
                output.fd.sync()
            }
            check(total > 0 && (expected < 0 || total == expected)) { "Incomplete audio download" }
            if (cancelled()) throw IOException("AUDIO_CANCELLED")
            check(validate(partial)) { "Unsupported or damaged audio" }
            val hash = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
            val id = "import_$hash"
            val target = File(directory, "$id.$extension")
            val created = !target.exists()
            if (target.exists()) {
                check(target.length() == total) { "Could not save audio" }
                check(partial.delete())
            } else check(partial.renameTo(target)) { "Could not save audio" }
            return Saved(id, target, total, created)
        } finally { partial.delete() }
    }

    fun remove(directory: File, path: String): Boolean {
        val file = File(path).canonicalFile
        if (file.parentFile != directory.canonicalFile || !file.name.matches(Regex("import_[a-f0-9]{64}\\.(mp3|ogg|wav|flac|dts|dtshd)"))) return false
        return !file.exists() || file.delete()
    }
}
