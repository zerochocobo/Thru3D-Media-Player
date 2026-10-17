package org.vrpassthroughplayer.plugin

import java.security.MessageDigest

/** Filesystem volume serials survive reattachment; USB session tokens deliberately do not. */
internal object UsbSubtitleIdentity {
    fun partition(part: UsbPartitions.Partition, sectorSize: Int, boot: ByteArray): String {
        val serial = when (part.filesystem) {
            "FAT32" -> 67 until 71
            "exFAT" -> 100 until 104
            "NTFS" -> 72 until 80
            else -> error("Unsupported USB filesystem")
        }
        require(boot.size >= 512 && boot.size >= serial.last + 1)
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update("${part.filesystem}:${part.first}:${part.count}:$sectorSize:".toByteArray(Charsets.UTF_8))
        digest.update(boot.copyOfRange(serial.first, serial.last + 1))
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }
}
