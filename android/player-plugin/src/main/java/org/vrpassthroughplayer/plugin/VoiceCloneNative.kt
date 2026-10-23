package org.vrpassthroughplayer.plugin

internal object VoiceCloneNative {
    init { System.loadLibrary("quest_narration") }
    @JvmStatic external fun createJob(): Long
    @JvmStatic external fun cancelJob(job: Long)
    @JvmStatic external fun extract(job: Long, path: String, stream: Int, ca: String, start: Double, end: Double, output: String, disc: Boolean, playlist: Int = -1)
    @JvmStatic external fun encode(model: String, wav: String, output: String)
    interface ScanListener { fun frames(start: Double, probability: FloatArray, rms: FloatArray, peak: FloatArray, finished: Boolean): Boolean }
    @JvmStatic external fun probe(job: Long, path: String, ca: String, disc: Boolean, playlist: Int): String
    @JvmStatic external fun scan(job: Long, path: String, stream: Int, ca: String, start: Double, end: Double, disc: Boolean, playlist: Int, model: String, listener: ScanListener)
}
