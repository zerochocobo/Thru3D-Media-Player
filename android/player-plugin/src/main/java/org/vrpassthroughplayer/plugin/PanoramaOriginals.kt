package org.vrpassthroughplayer.plugin

import java.io.File
import java.net.URI

/** Session-only originals. A download, viewer or public save owns a lease until it finishes. */
internal class PanoramaOriginals(private val directory: () -> File?) {
    private var root: File? = null
    private val leases = mutableMapOf<File, Int>()
    private var viewing: File? = null

    @Synchronized fun prepare(): File {
        root?.let { return it }
        val folder = requireNotNull(directory()).canonicalFile
        check(folder.mkdirs() || folder.isDirectory)
        // Only this dedicated private folder; never follow directories or links outside it.
        folder.listFiles()?.filter { it.isFile && it.canonicalFile.parentFile == folder }?.forEach { it.delete() }
        root = folder
        return folder
    }

    @Synchronized fun register(file: File) {
        require(file.canonicalFile.parentFile == prepare() && file.isFile)
        val key = file.canonicalFile
        leases[key] = (leases[key] ?: 0) + 1
    }

    @Synchronized fun retain(source: String): File? {
        val file = runCatching {
            val uri = URI(source)
            if (uri.scheme != "file" || !uri.authority.isNullOrEmpty()) return null
            File(uri).canonicalFile
        }.getOrNull() ?: return null
        if (file.parentFile != prepare() || !file.isFile || !leases.containsKey(file)) return null
        leases[file] = leases.getValue(file) + 1
        return file
    }

    @Synchronized fun view(source: String) {
        val next = retain(source)
        viewing?.let { release(it) }
        viewing = next
    }

    @Synchronized fun release(file: File) {
        val key = file.canonicalFile
        val count = leases[key] ?: return
        if (count > 1) leases[key] = count - 1
        else {
            leases.remove(key)
            key.delete()
            File(key.path + ".json").takeIf { it.canonicalFile.parentFile == root }?.delete()
        }
    }

    @Synchronized fun close() { viewing?.let { release(it) }; viewing = null }
}
