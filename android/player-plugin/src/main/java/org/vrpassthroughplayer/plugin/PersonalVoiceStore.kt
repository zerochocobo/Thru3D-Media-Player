package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.text.Normalizer
import java.util.Locale
import java.util.UUID

/** Persistent user data. Names never become paths; neither cache cleanup nor source deletion owns this directory. */
internal class PersonalVoiceStore(private val root: File) {
    companion object {
        const val CODEC = "moss-audio-nano-ceff0d0749bf-16x1024"
        fun isVoice(value: String) = value.matches(Regex("custom:[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"))
        fun hash(file: File): String = MessageDigest.getInstance("SHA-256").run {
            file.inputStream().use { stream -> val buffer=ByteArray(65536);while(true){val n=stream.read(buffer);if(n<0)break;update(buffer,0,n)} }
            digest().joinToString(""){"%02x".format(it)}
        }
        fun codes(file: File): IntArray {
            require(file.length() in (12+37*32).toLong()..(12+125*32).toLong())
            val bytes=file.readBytes();val data=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val magic=ByteArray(8);data.get(magic);require(String(magic,Charsets.US_ASCII)=="T3VOICE1")
            val frames=data.int;require(frames in 37..125&&bytes.size==12+frames*32)
            return IntArray(frames*16){(data.short.toInt() and 65535).also {require(it<1024)}}
        }
        fun name(value: String): String = Normalizer.normalize(value.trim(),Normalizer.Form.NFC).also {
            require(it.isNotEmpty()&&it.codePointCount(0,it.length)<=32&&it.none {c->c.isISOControl()}){"voice_name"}
        }
    }
    private fun folder(id: String): File {require(isVoice(id));return File(root,id.removePrefix("custom:"))}
    private fun metadata(id: String): JSONObject {
        val dir=folder(id);val f=File(dir,"voice.json");require(f.length() in 1..8192)
        val j=JSONObject(f.readText(Charsets.UTF_8));require(j.getInt("schema")==1&&j.getString("id")==id&&j.getString("codec")==CODEC)
        name(j.getString("name"));val file=File(dir,"codes.bin");codes(file);require(hash(file)==j.getString("revision"))
        require(File(dir,"reference.wav").length() in 576044..1920044);return j
    }
    @Synchronized fun list(): JSONArray = JSONArray().also { result ->
        root.listFiles()?.filter {it.isDirectory&&!it.name.startsWith('.') }?.mapNotNull {dir->runCatching {metadata("custom:"+dir.name)}.getOrNull()}
            ?.sortedByDescending {it.optLong("created") }?.forEach {result.put(it)}
    }
    @Synchronized fun load(id: String): IntArray {metadata(id);return codes(File(folder(id),"codes.bin"))}
    @Synchronized fun contains(id: String) = runCatching {metadata(id);true}.getOrDefault(false)
    private fun unique(value: String, excluding: String=""): String {
        val clean=name(value);val folded=clean.lowercase(Locale.ROOT);val all=list()
        require((0 until all.length()).none {all.getJSONObject(it).let {v->v.getString("id")!=excluding&&v.getString("name").lowercase(Locale.ROOT)==folded}}){"voice_name_exists"}
        return clean
    }
    private fun write(file: File, bytes: ByteArray) {FileOutputStream(file).use {it.write(bytes);it.fd.sync()}}
    @Synchronized fun save(value: String, reference: File, encoded: File): JSONObject {
        val clean=unique(value);val samples=codes(encoded);VoiceClonePolicy.readWav(reference)
        check(root.isDirectory||root.mkdirs());val uuid=UUID.randomUUID().toString();val staging=File(root,".saving-$uuid");check(staging.mkdir())
        try {
            write(File(staging,"codes.bin"),encoded.readBytes());write(File(staging,"reference.wav"),reference.readBytes())
            val meta=JSONObject().put("schema",1).put("id","custom:$uuid").put("name",clean).put("codec",CODEC)
                .put("reference_processing",VoiceReferencePcm.REVISION)
                .put("created",System.currentTimeMillis()).put("frames",samples.size/16).put("seconds",(reference.length()-44)/192000.0)
                .put("revision",hash(File(staging,"codes.bin"))).put("reference_sha256",hash(File(staging,"reference.wav")))
            write(File(staging,"voice.json"),meta.toString().toByteArray(Charsets.UTF_8))
            Files.move(staging.toPath(),File(root,uuid).toPath(),StandardCopyOption.ATOMIC_MOVE);return meta
        } finally {if(staging.exists())staging.deleteRecursively()}
    }
    @Synchronized fun rename(id: String,value: String) {
        val meta=metadata(id).put("name",unique(value,id));val dir=folder(id);val temp=File(dir,"voice.new")
        try {write(temp,meta.toString().toByteArray(Charsets.UTF_8));Files.move(temp.toPath(),File(dir,"voice.json").toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)}finally {temp.delete()}
    }
    @Synchronized fun delete(id: String) {val dir=folder(id);if(dir.exists()){check(dir.canonicalFile.parentFile==root.canonicalFile);check(dir.deleteRecursively())}}
}
