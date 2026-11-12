package org.vrpassthroughplayer.plugin

import org.codelibs.jcifs.smb.CIFSContext
import org.codelibs.jcifs.smb.impl.Handler
import org.codelibs.jcifs.smb.impl.SmbFile
import org.codelibs.jcifs.smb.impl.SmbAuthException
import org.codelibs.jcifs.smb.impl.SmbException
import java.net.URL
import java.util.Properties

/** CodeLibs uses jcifs.client.*, unlike the old jcifs-ng property prefix. */
internal object SmbClientPolicy {
    /** Only an authentication/permission rejection should open the credentials editor. */
    fun needsCredentials(error: Throwable): Boolean = generateSequence(error) { it.cause }.take(16).any {
        it is SmbAuthException || it is SmbException && it.ntStatus in setOf(
            0xC0000022.toInt(), /* ACCESS_DENIED */ 0xC000006D.toInt(), /* LOGON_FAILURE */
            0xC000006E.toInt(), /* ACCOUNT_RESTRICTION */ 0xC000006F.toInt(), /* INVALID_LOGON_HOURS */
            0xC0000070.toInt(), /* INVALID_WORKSTATION */ 0xC0000071.toInt(), /* PASSWORD_EXPIRED */
            0xC0000072.toInt(), /* ACCOUNT_DISABLED */ 0xC0000193.toInt(), /* ACCOUNT_EXPIRED */
            0xC0000224.toInt(), /* PASSWORD_MUST_CHANGE */ 0xC0000234.toInt()) /* ACCOUNT_LOCKED_OUT */
    }

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
        // for a guest login; server-required signing still wins.
        setProperty("jcifs.client.ipcSigningEnforced", (!guest).toString())
        setProperty("jcifs.resolveOrder", "DNS,BCAST")
    }
}
