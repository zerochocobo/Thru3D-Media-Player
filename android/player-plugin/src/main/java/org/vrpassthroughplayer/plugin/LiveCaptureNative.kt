package org.vrpassthroughplayer.plugin

internal object LiveCaptureNative {
    @Volatile var recording=false
    @Volatile var audioFailed=false
    private val loaded=try {System.loadLibrary("quest_mpv");true} catch(_:UnsatisfiedLinkError){false}
    fun available()=loaded&&runCatching {supported()}.getOrDefault(false)
    @JvmStatic private external fun supported(): Boolean
    @JvmStatic external fun start(owner: Long,path: String,positionUs: Long,playing: Boolean): Long
    @JvmStatic external fun clock(id: Long,positionUs: Long,playing: Boolean)
    @JvmStatic external fun limit(id: Long,positionUs: Long,presentationNs: Long)
    @JvmStatic external fun cancel(id: Long)
    @JvmStatic external fun stop(id: Long,positionUs: Long,presentationNs: Long)
    @JvmStatic external fun status(id: Long): String
    @JvmStatic external fun export(id: Long,output: String,mode: String): String
    @JvmStatic external fun forget(id: Long)
    @JvmStatic external fun narration(pcm: FloatArray,count: Int,presentationNs: Long,gain: Float)
}
