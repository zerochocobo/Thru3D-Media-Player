package org.vrpassthroughplayer.plugin

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Locale

internal object LocalStorageVolumePolicy {
    fun readOnlyPath(path: String, volumes: List<Pair<String, Boolean>>): Boolean {
        val candidate = File(path).canonicalPath.replace('\\', '/')
        return volumes.any { (location, removable) ->
            if (!removable || location.startsWith("content://")) return@any false
            val root = File(location).canonicalPath.replace('\\', '/').trimEnd('/')
            candidate == root || candidate.startsWith("$root/")
        }
    }
    fun mounted(state: String) = state == "mounted" || state == "mounted_ro"
    fun removable(removable: Boolean, primary: Boolean, emulated: Boolean) = removable && !primary && !emulated
    fun publicDirectory(directory: String?): Boolean = directory != null && directory.startsWith("/storage/") &&
        directory.split('/').none { it == "." || it == ".." }
    /** Null means untested, so first-time permission requests cannot change a public entry ID. */
    fun probeDirectoryReadability(directory: String?, removable: Boolean, permission: Boolean, probe: () -> Boolean): Boolean? =
        if (removable && publicDirectory(directory) && permission) probe() else null
    data class Access(val location: String, val documentOnly: Boolean)
    /** A UUID identifies a registered mounted volume, not a grant or a guessed filesystem path. */
    fun access(state: String, directory: String?, uuid: String?, removable: Boolean, directoryReadable: Boolean? = null): Access? {
        if (!mounted(state)) return null
        // A non-null StorageVolume.directory can still be a private /mnt/media_rw path.
        if (directory != null && (!removable || (publicDirectory(directory) && directoryReadable != false)))
            return Access(directory, false)
        if (!removable || uuid == null || !Regex("[A-Za-z0-9-]{1,64}").matches(uuid)) return null
        val root = StorageDocumentPolicy.id("$uuid:")
        return Access(StorageDocumentPolicy.document(root, root), true)
    }
    /** Pin missing/private-path entries only; a permission-dependent probe failure is reversible. */
    class Discovery {
        private val documentRoots = mutableMapOf<String, Access>()
        @Synchronized fun select(state: String, directory: String?, uuid: String?, removable: Boolean, directoryReadable: Boolean? = null): Access? {
            val current = access(state, directory, uuid, removable, directoryReadable) ?: return null
            if (!removable || uuid == null) return current
            val key = uuid.lowercase(Locale.ROOT)
            if (current.documentOnly && !publicDirectory(directory)) documentRoots.putIfAbsent(key, current)
            return documentRoots[key] ?: current
        }
    }
    fun legacyCandidates(uuid: String?, appDirectories: List<String>): List<String> {
        val candidates = mutableListOf<String>()
        if (uuid != null && Regex("[A-Za-z0-9-]{1,64}").matches(uuid)) candidates.add("/storage/$uuid")
        for (path in appDirectories) {
            val marker = path.indexOf("/Android/data/")
            if (marker > 0) candidates.add(path.substring(0, marker))
        }
        return candidates.distinct()
    }
}

internal object LocalStorageVolumes {
    private val discovery = LocalStorageVolumePolicy.Discovery()
    @Volatile private var lastDiagnostic = ""
    fun roots(context: Context): JSONArray {
        val result = JSONArray()
        val manager = context.getSystemService(StorageManager::class.java) ?: return result
        val volumes = manager.storageVolumes
        val mayProbe = LocalStoragePermissions.canProbeDirectory(Build.VERSION.SDK_INT,
            Build.VERSION.SDK_INT >= 30 && Environment.isExternalStorageManager(),
            Build.VERSION.SDK_INT <= 32 && context.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED)
        var mounted = 0; var documentOnly = 0; var skipped = 0
        for (volume in volumes) {
            if (!LocalStorageVolumePolicy.mounted(volume.state)) continue
            mounted++
            val directory = if (Build.VERSION.SDK_INT >= 30) volume.directory else if (volume.isPrimary)
                Environment.getExternalStorageDirectory() else {
                // Android 10 has no public StorageVolume.directory. Verify every fallback through
                // the public manager; a UUID-shaped path alone is never considered a mounted disk.
                fun verified(paths: List<String>) = paths.asSequence().map(::File).firstOrNull {
                    runCatching { manager.getStorageVolume(it) == volume }.getOrDefault(false)
                }
                verified(LocalStorageVolumePolicy.legacyCandidates(volume.uuid, emptyList()))
                    // Context.getExternalFilesDirs() may create Android/data directories on
                    // the disk. Discover visible public roots without modifying the source.
                    ?: verified(File("/storage").listFiles()?.map { it.absolutePath }.orEmpty())
            }
            val removable = LocalStorageVolumePolicy.removable(volume.isRemovable,volume.isPrimary,volume.isEmulated)
            val directoryReadable = LocalStorageVolumePolicy.probeDirectoryReadability(directory?.absolutePath,removable,mayProbe) {
                runCatching { directory != null && directory.isDirectory && directory.canRead() }.getOrDefault(false)
            }
            val access = discovery.select(volume.state,directory?.absolutePath,volume.uuid,removable,directoryReadable)
            if (access == null) { skipped++; continue }
            if (access.documentOnly) documentOnly++
            result.put(JSONObject().put("id",access.location).put("title",volume.getDescription(context))
                .put("container",true).put("volume",true).put("uuid",volume.uuid ?: "")
                .put("removable",removable).put("document_only",access.documentOnly)
                .put("storage_access","system").put("managed_usb",false)
                .put("read_only",volume.isRemovable || volume.state == Environment.MEDIA_MOUNTED_READ_ONLY))
        }
        // Counts only: no volume labels, UUIDs, device serials or media paths. Log changed snapshots.
        if (PlaybackPrivacy.diagnostics) {
            val diagnostic = "volumes sdk=${Build.VERSION.SDK_INT} registered=${volumes.size} mounted=$mounted checking=${volumes.count { it.state == Environment.MEDIA_CHECKING }} document_only=$documentOnly skipped=$skipped"
            if (diagnostic != lastDiagnostic) { lastDiagnostic = diagnostic; Log.i("ThruStorage", diagnostic) }
        }
        return result
    }
}
