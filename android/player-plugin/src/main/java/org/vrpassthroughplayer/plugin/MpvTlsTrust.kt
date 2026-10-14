package org.vrpassthroughplayer.plugin

import android.content.Context
import java.io.File
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.util.Base64
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/** Native curl has no Android CA path. Export the app's default public trust anchors as PEM. */
internal object MpvTlsTrust {
    private var cached: File? = null

    @Synchronized fun prepare(context: Context): String {
        cached?.takeIf { it.isFile && it.length() > 0 }?.let { return it.absolutePath }
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(null as KeyStore?)
        val anchors = factory.trustManagers.filterIsInstance<X509TrustManager>().flatMap { it.acceptedIssuers.toList() }
        val file = File(context.cacheDir, "mpv-system-ca.pem")
        val temporary = File(context.cacheDir, "mpv-system-ca.pem.tmp")
        temporary.writeText(pem(anchors), Charsets.US_ASCII)
        check(temporary.renameTo(file)) { "System TLS certificate cache unavailable" }
        cached = file
        return file.absolutePath
    }

    fun pem(certificates: List<X509Certificate>): String {
        require(certificates.isNotEmpty()) { "System TLS certificates unavailable" }
        val encoder = Base64.getMimeEncoder(64, byteArrayOf(10))
        return certificates.distinctBy { encoder.encodeToString(it.encoded) }.joinToString("") {
            "-----BEGIN CERTIFICATE-----\n" + encoder.encodeToString(it.encoded) + "\n-----END CERTIFICATE-----\n"
        }
    }
}
