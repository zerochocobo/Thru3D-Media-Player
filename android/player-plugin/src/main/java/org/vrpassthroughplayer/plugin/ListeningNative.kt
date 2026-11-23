package org.vrpassthroughplayer.plugin

internal object ListeningNative {
    init { System.loadLibrary("quest_listening") }
    /** Short VAD segments for a live stream; [createAhead] waits for whole sentences.
     * With a Silero model path [createAhead] decodes Silero speech segments whole. */
    @JvmStatic external fun create(directory: String, language: String): Long
    @JvmStatic external fun createAhead(directory: String, language: String, vad: String): Long
    @JvmStatic external fun open(engine: Long, path: String, track: Int, ca: String, start: Double, disc: Boolean, playlist: Int)
    @JvmStatic external fun openWithClock(engine: Long, path: String, track: Int, ca: String, start: Double, disc: Boolean, playlist: Int, origin: Double, directAudio: Boolean, input: ListeningInput? = null)
    @JvmStatic external fun step(engine: Long): String
    @JvmStatic external fun recognizePcm(engine: Long, pcm: ByteArray, rate: Int, channels: Int, reset: Boolean): String
    @JvmStatic external fun audioSpans(engine: Long): LongArray
    @JvmStatic external fun begin(engine: Long)
    @JvmStatic external fun cancel(engine: Long)
    @JvmStatic external fun destroy(engine: Long)
}
