package org.vrpassthroughplayer.plugin

import java.io.File
import java.util.concurrent.Executors

/** The previous decoder retires on this worker before the next one allocates its canvas. */
internal class MediaArtworkPlayer {
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "MediaArtwork") }
    private var session: AnimatedPhotoSession? = null
    private var serial = 0
    private var closed = false

    @Synchronized fun start(cacheDir: File, path: String, edge: Int): Int {
        if (closed) return 0
        val file = File(path).canonicalFile
        val root = File(cacheDir, MediaServerPosterCache.DIRECTORY).canonicalFile
        if (file.extension != "anim" || file.parentFile?.parentFile != root || !file.isFile) return 0
        stop()
        val backend = object : PhotoAnimationBackend by NativePhotoAnimationBackend {
            override fun open(path: String) = ExtendedImageNative.open(path, edge.coerceIn(64, 640), false)
        }
        session = AnimatedPhotoSession(null, backend, worker, ownsWorker = false, file = file)
        return ++serial
    }

    @Synchronized fun poll(id: Int) = if (id == serial) session?.poll().orEmpty() else ""
    @Synchronized fun pixels(id: Int, token: Long) =
        if (id == serial) session?.pixels(token) ?: ByteArray(0) else ByteArray(0)
    @Synchronized fun upload(id: Int, token: Long, texture: Int) =
        id == serial && session?.upload(token, texture, false) == true
    @Synchronized fun stop(id: Int = serial) {
        if (id == serial) { session?.close(); session = null }
    }
    @Synchronized fun close() { closed = true; stop(); worker.shutdown() }
}
