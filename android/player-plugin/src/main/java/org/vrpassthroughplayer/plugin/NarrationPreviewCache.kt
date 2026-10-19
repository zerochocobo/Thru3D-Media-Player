package org.vrpassthroughplayer.plugin

import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID
import kotlin.math.roundToInt

/** Saved voices/presets are persistent; only unsaved subtitle samples participate in LRU eviction. */
internal class NarrationPreviewCache(private val persistent: File,private val temporary: File,
                                    private val temporaryLimit: Long=16L*1024*1024) {
    init {
        // Incomplete writes from a terminated process are not saved previews.
        fun incomplete(directory: File){directory.listFiles()?.filter {it.isFile&&it.name.startsWith(".writing-")}?.forEach {it.delete()}}
        incomplete(temporary)
        persistent.listFiles()?.filter {it.isDirectory}?.forEach {incomplete(it)}
        trim()
    }
    companion object {
        const val MAX_SAMPLES=1_920_000 // stereo, 48 kHz, at most 20 seconds
        private const val HEADER=108L
        private val MAGIC="T3PCM002".toByteArray(Charsets.US_ASCII)
        fun key(voice: String,language: String,text: String,model: String,codes: IntArray): String {
            val digest=MessageDigest.getInstance("SHA-256")
            for(value in listOf(voice,language,text,model,"pcm16-v3-reference-level")){digest.update(value.toByteArray());digest.update(0.toByte())}
            val encoded=ByteBuffer.allocate(codes.size*4);codes.forEach {encoded.putInt(it)};digest.update(encoded.array())
            return digest.digest().joinToString(""){"%02x".format(it)}
        }
    }
    data class Entry(val file: File,val samples: Int) {
        fun read(active: ()->Boolean,consume: (FloatArray)->Unit) {
            RandomAccessFile(file,"r").use {input->input.seek(HEADER);var left=samples
                val bytes=ByteArray(15360)
                while(left>0){check(active()){"voice_cancelled"};val count=minOf(left,bytes.size/2);input.readFully(bytes,0,count*2)
                    val pcm=ByteBuffer.wrap(bytes,0,count*2).order(ByteOrder.LITTLE_ENDIAN)
                    consume(FloatArray(count){pcm.short/32768f});left-=count}
            }
        }
    }
    private fun target(voice: String,language: String,key: String,saved: Boolean): File {
        require(key.matches(Regex("[0-9a-f]{64}")))
        if(!saved)return File(temporary,"$key.pcm")
        require(PersonalVoiceStore.isVoice(voice)||voice in NarrationPolicy.voices.values.flatten())
        require(language in NarrationPolicy.languages)
        return File(persistent,voice.replace(':','-')+"/"+language+"-"+key+".pcm")
    }
    fun find(voice: String,language: String,key: String,saved: Boolean,active: ()->Boolean): Entry? {
        val file=target(voice,language,key,saved)
        if(!file.isFile)return null
        return try {
            RandomAccessFile(file,"r").use {input->
                val magic=ByteArray(8);input.readFully(magic);require(magic.contentEquals(MAGIC))
                val identity=ByteArray(64);input.readFully(identity);require(String(identity,Charsets.US_ASCII)==key)
                val count=input.readInt();require(count in 2..MAX_SAMPLES&&count%2==0&&input.length()==HEADER+count*2L)
                val expected=ByteArray(32);input.readFully(expected);val hash=MessageDigest.getInstance("SHA-256");val buffer=ByteArray(32768)
                while(true){check(active()){"voice_cancelled"};val n=input.read(buffer);if(n<0)break;hash.update(buffer,0,n)}
                require(hash.digest().contentEquals(expected));file.setLastModified(System.currentTimeMillis());Entry(file,count)
            }
        } catch(error: Exception){if(!active())throw error;if(!saved)file.delete();null}
    }
    inner class Writer internal constructor(private val target: File,private val key: String,private val saved: Boolean): AutoCloseable {
        private val staging=File(target.parentFile,".writing-"+UUID.randomUUID())
        private val output: BufferedOutputStream
        private val digest=MessageDigest.getInstance("SHA-256")
        private var count=0
        private var finished=false
        init {
            check(target.parentFile!!.isDirectory||target.parentFile!!.mkdirs())
            output=BufferedOutputStream(FileOutputStream(staging),32768)
            output.write(MAGIC);output.write(key.toByteArray(Charsets.US_ASCII));output.write(ByteArray(36))
        }
        fun append(pcm: FloatArray) {
            require(!finished&&pcm.size%2==0&&count+pcm.size<=MAX_SAMPLES)
            val bytes=ByteBuffer.allocate(pcm.size*2).order(ByteOrder.LITTLE_ENDIAN)
            pcm.forEach {require(it.isFinite());bytes.putShort((it.coerceIn(-1f,1f)*32767).roundToInt().toShort())}
            output.write(bytes.array());digest.update(bytes.array());count+=pcm.size
        }
        fun complete(active: ()->Boolean): Entry {
            check(!finished&&count>0&&active());output.close()
            RandomAccessFile(staging,"rw").use {it.seek(72);it.writeInt(count);it.write(digest.digest());it.fd.sync()}
            check(active()){"voice_cancelled"}
            Files.move(staging.toPath(),target.toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
            finished=true;if(!saved)trim()
            return Entry(target,count)
        }
        override fun close(){runCatching {output.close()};if(!finished)staging.delete()}
    }
    fun writer(voice: String,language: String,key: String,saved: Boolean)=Writer(target(voice,language,key,saved),key,saved)
    @Synchronized private fun trim() {
        val files=temporary.listFiles()?.filter {it.isFile&&it.name.matches(Regex("[0-9a-f]{64}\\.pcm"))}?.sortedBy {it.lastModified()} ?: return
        var bytes=files.sumOf {it.length()}
        for(file in files){if(bytes<=temporaryLimit)break;val size=file.length();if(file.delete())bytes-=size}
    }
    fun deleteVoice(voice: String) {
        require(PersonalVoiceStore.isVoice(voice));val folder=File(persistent,voice.replace(':','-')).canonicalFile
        require(folder.parentFile==persistent.canonicalFile)
        if(folder.exists())check(folder.deleteRecursively())
    }
}
