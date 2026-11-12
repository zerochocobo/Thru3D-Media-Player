package org.vrpassthroughplayer.plugin

import org.codelibs.jcifs.smb.DialectVersion
import org.codelibs.jcifs.smb.config.PropertyConfiguration
import org.codelibs.jcifs.smb.internal.smb2.Smb2EncryptionContext
import org.junit.Assert.*
import org.junit.Test
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class SmbClientPolicyTest {
    @Test fun credentialPromptDistinguishesAuthenticationFromTransportAndMissingShares() {
        for (status in listOf(0xC0000022.toInt(), 0xC000006D.toInt(), 0xC0000072.toInt(), 0xC0000234.toInt())) {
            val error = org.codelibs.jcifs.smb.impl.SmbException(status, false)
            assertTrue(SmbClientPolicy.needsCredentials(java.io.IOException("Browse failed", error)))
        }
        for (error in listOf(java.net.SocketTimeoutException(), java.net.UnknownHostException(),
            java.io.IOException("access denied text is not an SMB status"),
            org.codelibs.jcifs.smb.impl.SmbException(0xC00000CC.toInt(), false),
            org.codelibs.jcifs.smb.impl.SmbException(0xC00000C9.toInt(), false))) {
            assertFalse(SmbClientPolicy.needsCredentials(error))
        }
    }

    @Test fun acceptsDirectSharesWithoutChangingExistingServerAddresses() {
        assertEquals("192.168.1.2", SmbClientPolicy.address("smb://192.168.1.2/"))
        assertEquals("PC/Movies/Sub folder", SmbClientPolicy.address("\\\\PC\\Movies\\Sub folder"))
        assertThrows(IllegalArgumentException::class.java) { SmbClientPolicy.address("PC/share/../other") }
        assertThrows(IllegalArgumentException::class.java) { SmbClientPolicy.address("user:password@PC") }
    }
    @Test fun configuredLibrarySupportsModernNegotiationAndExplicitGuest() {
        val config = PropertyConfiguration(SmbClientPolicy.properties(false))
        assertEquals(DialectVersion.SMB202, config.minimumVersion)
        assertEquals(DialectVersion.SMB311, config.maximumVersion)
        assertTrue(config.isEncryptionEnabled)
        assertTrue(config.isIpcSigningEnforced)
        assertFalse(PropertyConfiguration(SmbClientPolicy.properties(true)).isIpcSigningEnforced)
    }
    @Test fun smb311TransformInteroperatesWithJceGcm() {
        val key = ByteArray(16) { it.toByte() }
        val data = ByteArray(257) { (it * 13).toByte() }
        val context = Smb2EncryptionContext(2, DialectVersion.SMB311, key, key)
        val packet = context.encryptMessage(data, 123L)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, packet.copyOfRange(20, 32)))
        cipher.updateAAD(packet.copyOfRange(20, 52))
        assertArrayEquals(data, cipher.doFinal(packet.copyOfRange(52, packet.size) + packet.copyOfRange(4, 20)))
        assertArrayEquals(data, context.decryptMessage(packet))
        assertFalse(packet.contentEquals(context.encryptMessage(data, 123L)))
    }
    @Test fun smb300CcmRejectsModifiedPackets() {
        val key = ByteArray(16) { it.toByte() }
        val context = Smb2EncryptionContext(1, DialectVersion.SMB300, key, key)
        val data = ByteArray(71) { it.toByte() }
        val packet = context.encryptMessage(data, 4L)
        assertArrayEquals(data, context.decryptMessage(packet))
        packet[packet.lastIndex] = (packet.last().toInt() xor 1).toByte()
        assertThrows(org.codelibs.jcifs.smb.CIFSException::class.java) { context.decryptMessage(packet) }
    }
}
