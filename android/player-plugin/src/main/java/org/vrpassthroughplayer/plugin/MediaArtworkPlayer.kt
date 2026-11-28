package org.vrpassthroughplayer.plugin

import java.io.File
import java.util.concurrent.Executors

/** Decoders share one worker; queued closes run before new canvases are allocated. */
internal class MediaArtworkPlayer {
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "MediaArtwork") }
    private val sessions = mutableMapOf<Int, AnimatedPhotoSession>()
    private var serial = 0
    private var closed = false

    @Synchronized fun start(cacheDir: File, path: String, edge: Int): Int {
        if (closed || sessions.size >= 3) return 0
        val file = File(path).canonicalFile
        val root = File(cacheDir, MediaServerPosterCache.DIRECTORY).canonicalFile
        if (file.extension != "anim" || file.parentFile?.parentFile != root || !file.isFile) return 0
        val backend = object : PhotoAnimationBackend by NativePhotoAnimationBackend {
            override fun open(path: String) = ExtendedImageNative.open(path, edge.coerceIn(64, 640), false)
        }
        val id = ++serial
        sessions[id] = AnimatedPhotoSession(null, backend, worker, ownsWorker = false, file = file)
        return id
    }

    @Synchronized fun poll(id: Int) = sessions[id]?.poll().orEmpty()
    @Synchronized fun pixels(id: Int, token: Long) =
        sessions[id]?.pixels(token) ?: ByteArray(0)
    @Synchronized fun upload(id: Int, token: Long, texture: Int) =
        sessions[id]?.upload(token, texture, false) == true
    @Synchronized fun stop(id: Int) { sessions.remove(id)?.close() }
    @Synchronized fun stop() {
        sessions.values.forEach { it.close() }
        sessions.clear()
    }
    @Synchronized fun close() { closed = true; stop(); worker.shutdown() }
}
