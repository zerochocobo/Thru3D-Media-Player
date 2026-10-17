package org.vrpassthroughplayer.plugin

internal object NarrationNative {
    private val loaded = try { System.loadLibrary("quest_narration"); true } catch (_: UnsatisfiedLinkError) { false }
    fun supported() = loaded
    interface Sink { fun onChunk(epoch: Long, pcm: FloatArray): Boolean }
    @JvmStatic external fun create(directory: String): Long
    @JvmStatic external fun cancel(engine: Long, epoch: Long)
    @JvmStatic external fun destroy(engine: Long)
    @JvmStatic external fun synthesize(engine: Long, text: String, voice: String, epoch: Long, sink: Sink): String
    @JvmStatic external fun openReader(path: String, stream: Int, caFile: String): Long
    @JvmStatic external fun readWindow(reader: Long, start: Double, end: Double): String
    @JvmStatic external fun closeReader(reader: Long)
}
