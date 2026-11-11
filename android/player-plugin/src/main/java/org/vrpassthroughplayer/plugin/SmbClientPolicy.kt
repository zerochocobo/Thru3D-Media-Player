package org.vrpassthroughplayer.plugin

import org.codelibs.jcifs.smb.CIFSContext
import org.codelibs.jcifs.smb.impl.Handler
import org.codelibs.jcifs.smb.impl.SmbFile
import java.net.URL
import java.util.Properties

/** CodeLibs uses jcifs.client.*, unlike the old jcifs-ng property prefix. */
internal object SmbClientPolicy {
    /** Accept a server or a direct share (including Windows UNC form). */
    fun address(value: String): String {
        val normalized = value.trim().replace('\\', '/').removePrefix("smb://").trim('/')
        val host = normalized.substringBefore('/')
        require(host.isNotEmpty() && host.matches(Regex("[A-Za-z0-9_.:\\[\\]-]+"))) { "SMB address invalid" }
        require(normalized.split('/').none { it == ".." || it == "." || it.isEmpty() }) { "SMB path invalid" }
        require(!normalized.contains('?') && !normalized.contains('#')) { "SMB path invalid" }
        return normalized
    }

    fun file(location: String, context: CIFSContext): SmbFile {
        if ('?' !in location && '#' !in location && '%' !in location) return SmbFile(location, context)
        val relative = location.removePrefix("smb://")
        val authority = relative.substringBefore('/')
        val path = "/" + relative.substringAfter('/')
        // JCIFS consumes the URL path literally. Set it directly so # and ? stay
        // in the name and percent sequences such as %2F remain ordinary text.
        val handler = object : Handler(context) {
            fun literalUrl(): URL {
                val url = URL(null, "smb://$authority/", this)
                setURL(url, url.protocol, url.host, url.port, url.authority, url.userInfo, path, null, null)
                return url
            }
        }
        return SmbFile(handler.literalUrl(), context)
    }

    fun properties(guest: Boolean) = Properties().apply {
        setProperty("jcifs.client.minVersion", "SMB202")
        setProperty("jcifs.client.maxVersion", "SMB311")
        setProperty("jcifs.client.useSMB2Negotiation", "true")
        setProperty("jcifs.client.encryptionEnabled", "true")
        setProperty("jcifs.client.responseTimeout", "15000")
        setProperty("jcifs.client.connTimeout", "5000")
        // Guest sessions have no signing key. Only relax the client's IPC preference
        // for an explicitly selected guest login; server-required signing still wins.
        setProperty("jcifs.client.ipcSigningEnforced", (!guest).toString())
        setProperty("jcifs.resolveOrder", "DNS,BCAST")
    }
}
