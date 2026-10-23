package org.vrpassthroughplayer.plugin

internal object VoiceCloneNative {
    init { System.loadLibrary("quest_narration") }
    @JvmStatic external fun createJob(): Long
    @JvmStatic external fun cancelJob(job: Long)
    @JvmStatic external fun extract(job: Long, path: String, stream: Int, ca: String, start: Double, end: Double, output: String, disc: Boolean, playlist: Int = -1)
    @JvmStatic external fun encode(model: String, wav: String, output: String)
}
