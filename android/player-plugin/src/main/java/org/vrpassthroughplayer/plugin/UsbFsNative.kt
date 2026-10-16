package org.vrpassthroughplayer.plugin

internal object UsbFsNative {
    val available = runCatching { System.loadLibrary("quest_usb") }.isSuccess
    @JvmStatic external fun mount(reader: Any, length: Long, sector: Int, ntfs: Boolean): Long
    @JvmStatic external fun list(volume: Long, path: ByteArray): ByteArray
    @JvmStatic external fun open(volume: Long, path: ByteArray): Long
    @JvmStatic external fun size(file: Long): Long
    @JvmStatic external fun read(file: Long, offset: Long, buffer: ByteArray, length: Int): Int
    @JvmStatic external fun closeFile(file: Long)
    @JvmStatic external fun closeVolume(volume: Long)
}
