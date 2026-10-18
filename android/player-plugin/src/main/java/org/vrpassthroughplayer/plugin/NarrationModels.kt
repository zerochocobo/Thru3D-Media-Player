package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID

/** Lazily installs verified APK assets into private storage for native file access. */
internal object NarrationModels {
    fun ensure(directory: File, files: JSONObject, open: (String) -> InputStream,
               active: () -> Boolean, verified: (Long) -> Unit) {
        val root=directory.canonicalFile
        check(root.isDirectory || root.mkdirs())
        for(name in files.keys()) {
            require(!name.startsWith('/') && !name.contains('\\') && !name.contains(':') && name.split('/').none {it==".." || it.isEmpty()})
            val target=File(root,name).canonicalFile
            require(target.path.startsWith(root.path+File.separator))
            val expected=files.getJSONObject(name)
            val size=expected.getLong("bytes");val hash=expected.getString("sha256")
            fun read(input: InputStream, output: FileOutputStream? = null): Boolean {
                val digest=MessageDigest.getInstance("SHA-256");var total=0L
                input.use { stream ->
                    val buffer=ByteArray(128*1024)
                    while(true) {
                        check(active()) {"Cancelled"}
                        val count=stream.read(buffer);if(count<0)break
                        total+=count;require(total<=size)
                        digest.update(buffer,0,count);output?.write(buffer,0,count)
                    }
                }
                return total==size && digest.digest().joinToString("") {"%02x".format(it)}==hash
            }
            if(target.isFile && target.length()==size && read(target.inputStream())) {
                verified(size);continue
            }
            check(target.parentFile!!.isDirectory || target.parentFile!!.mkdirs())
            val temporary=File(target.parentFile,target.name+".installing-"+UUID.randomUUID())
            try {
                FileOutputStream(temporary).use { output ->
                    require(read(open(name),output)) {"Invalid bundled narration model"}
                    output.fd.sync()
                }
                check(active()) {"Cancelled"}
                Files.move(temporary.toPath(),target.toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
                verified(size)
            } finally { temporary.delete() }
        }
    }
}
