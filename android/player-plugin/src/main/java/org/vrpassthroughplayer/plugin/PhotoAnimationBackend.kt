package org.vrpassthroughplayer.plugin

internal interface PhotoAnimationBackend {
    fun open(path: String): Long
    fun info(id: Long): LongArray?
    fun next(id: Long,check: Runnable): LongArray?
    fun reset(id: Long)
    fun pixels(token: Long): ByteArray?
    fun upload(token: Long,texture: Int,mipmaps: Boolean): Boolean
    fun releaseFrame(token: Long)
    fun close(id: Long)
}
internal object NativePhotoAnimationBackend: PhotoAnimationBackend {
    override fun open(path: String)=ExtendedImageNative.open(path,2048,false)
    override fun info(id: Long)=ExtendedImageNative.info(id)
    override fun next(id: Long,check: Runnable)=ExtendedImageNative.next(id,check)
    override fun reset(id: Long)=ExtendedImageNative.reset(id)
    override fun pixels(token: Long)=ExtendedImageNative.pixels(token)
    override fun upload(token: Long,texture: Int,mipmaps: Boolean)=ExtendedImageNative.upload(token,texture,mipmaps)
    override fun releaseFrame(token: Long)=ExtendedImageNative.releaseFrame(token)
    override fun close(id: Long)=ExtendedImageNative.close(id)
}
