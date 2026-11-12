package org.vrpassthroughplayer.plugin

/** Scene import natives (native/unity-scene), built into libquest_rvm: Unity bundle unpacker and ETC2 encoder. Blocking; call off the main thread. */
internal object UnityScene {
    private val loaded = try { System.loadLibrary("quest_rvm"); true } catch (_: UnsatisfiedLinkError) { false }
    private external fun unpack(bundle: String, output: String, maxTexture: Int, maxSkyTexture: Int): String?

    private external fun encodeEtc2(rgba: ByteArray, width: Int, height: Int, alpha: Boolean, chain: Boolean, threads: Int): ByteArray?

    /** RGBA8 mip chain to an ETC2 mip chain; empty when unavailable or the input does not fit its size. */
    fun etc2(rgba: ByteArray, width: Int, height: Int, alpha: Boolean): ByteArray =
        if (!loaded) ByteArray(0) else encodeEtc2(rgba, width, height, alpha, true, 3) ?: ByteArray(0)

    /** Empty on success, otherwise a short reason. */
    fun run(bundle: String, output: String, maxTexture: Int, maxSkyTexture: Int): String =
        if (!loaded) "Unity scenes are not supported on this build" else unpack(bundle, output, maxTexture, maxSkyTexture).orEmpty()
}
