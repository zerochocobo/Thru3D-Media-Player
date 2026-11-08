package org.vrpassthroughplayer.plugin

internal object MirrorAudioFormat {
    fun aacConfig(codec: Int, samples: Int, rate: Int, channels: Int): ByteArray {
        require(codec in listOf(4, 8) && samples in listOf(480, 512, 960, 1024) && rate in listOf(44100, 48000) && channels in 1..2)
        if (codec == 8) {
            require(rate == 44100 && channels == 2)
            return byteArrayOf(0xf8.toByte(), 0xe8.toByte(), if (samples == 512) 0x40 else 0x50, 0)
        }
        val asc = (2 shl 11) or ((if (rate == 48000) 3 else 4) shl 7) or (channels shl 3) or (if (samples == 960) 4 else 0)
        return byteArrayOf((asc shr 8).toByte(), asc.toByte())
    }
}
