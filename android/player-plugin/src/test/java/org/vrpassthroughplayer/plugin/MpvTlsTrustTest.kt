package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.security.KeyStore
import java.security.cert.CertificateFactory
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

class MpvTlsTrustTest {
    @Test fun exportsPublicDefaultTrustAnchorsAsParseablePemWithoutDuplicates() {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(null as KeyStore?)
        val anchors = factory.trustManagers.filterIsInstance<X509TrustManager>().flatMap { it.acceptedIssuers.toList() }.take(3)
        assertTrue(anchors.isNotEmpty())
        val pem = MpvTlsTrust.pem(anchors + anchors)
        assertFalse(pem.contains("PRIVATE KEY"))
        val decoded = CertificateFactory.getInstance("X.509").generateCertificates(pem.byteInputStream())
        assertEquals(anchors.size, decoded.size)
        anchors.zip(decoded).forEach { (expected, actual) -> assertArrayEquals(expected.encoded, actual.encoded) }
    }
    @Test fun rejectsAnEmptyTrustStoreRatherThanTurningOffVerification() {
        assertThrows(IllegalArgumentException::class.java) { MpvTlsTrust.pem(emptyList()) }
    }
}
