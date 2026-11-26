package org.vrpassthroughplayer.plugin

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS

/** Disposable photo/archive caches; never model programs, media originals or credentials. */
internal object PhotoCache {
    val lock = Any()
    private val photoNames = listOf("photos", "photo-preloads", "photo-gallery", "pip-images")
    private val readingNames = listOf("comic-pages", "pdf-pages", "pdf-sources", "book-pages")
    // Kept between runs: the user's cache cleanup and its size count include them, the cleanup at start does not.
    private val lasting = listOf(PhotoDepthStore.NAME)
    private val lastingReading = listOf("book-layouts")

    private fun directories(category: String, leftovers: Boolean = false): List<String> = when (category) {
        "photo" -> photoNames + lasting
        "reading" -> readingNames + lastingReading
        else -> photoNames + readingNames + if (leftovers) emptyList() else lasting + lastingReading
    }

    fun usage(cache: File, category: String = ""): Pair<Long, Long> = synchronized(lock) {
        var count = 0L
        var bytes = 0L
        for (name in directories(category)) {
            val root = File(cache, name).toPath()
            if (!Files.isDirectory(root, NOFOLLOW_LINKS)) continue
            Files.walk(root).use { paths -> paths.forEach { path ->
                if (Files.isRegularFile(path, NOFOLLOW_LINKS)) {
                    // A photo may be released while settings is counting its files.
                    runCatching { Files.size(path) }.getOrNull()?.let { size -> count++; bytes += size }
                }
            } }
        }
        count to bytes
    }

    fun clear(cache: File, protected: Set<File>, leftovers: Boolean = false, category: String = "") = synchronized(lock) {
        val active = protected.map { it.absoluteFile.toPath().normalize() }.toSet()
        for (name in directories(category, leftovers)) {
            val root = File(cache, name).absoluteFile.toPath().normalize()
            // An archive owns its original cache and extracted pages as one live session.
            if (root in active) continue
            if (!Files.isDirectory(root, NOFOLLOW_LINKS)) continue
            Files.list(root).use { entries -> entries.forEach { entry ->
                if (entry !in active) {
                    // walk does not follow links, including links to another cache or original.
                    Files.walk(entry).use { paths ->
                        paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
                    }
                }
            } }
        }
    }
}
