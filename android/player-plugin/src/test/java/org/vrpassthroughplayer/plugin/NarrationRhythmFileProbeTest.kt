package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

/** Opt-in desktop probe. Personal PCM stays in the explicitly supplied ignored
 * directory and never becomes a packaged fixture or repository test asset. */
class NarrationRhythmFileProbeTest {
    private fun digest(file: File)=MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString(""){"%02x".format(it)}
    private fun read(file: File): FloatArray {
        val bytes=file.readBytes();val buffer=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        require(String(bytes,0,4)=="RIFF"&&String(bytes,8,4)=="WAVE")
        require(buffer.getShort(20).toInt()==1&&buffer.getShort(22).toInt()==2&&buffer.getInt(24)==48000&&buffer.getShort(34).toInt()==16)
        require(String(bytes,36,4)=="data"&&buffer.getInt(40)==bytes.size-44)
        buffer.position(44);return FloatArray((bytes.size-44)/2){buffer.short/32768f}
    }
    private fun write(file: File,chunks: List<FloatArray>) {
        val count=chunks.sumOf {it.size};val buffer=ByteBuffer.allocate(44+count*2).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray()).putInt(36+count*2).put("WAVEfmt ".toByteArray()).putInt(16)
            .putShort(1).putShort(2).putInt(48000).putInt(192000).putShort(4).putShort(16).put("data".toByteArray()).putInt(count*2)
        chunks.forEach {it.forEach {sample->buffer.putShort((sample*32768f).toInt().coerceIn(-32768,32767).toShort())}}
        file.writeBytes(buffer.array())
    }
    @Test fun privateRealWaveformsProduceAuditablePlaybackCopiesWithoutEditingSources() {
        val manifest=System.getenv("THRU3D_RHYTHM_FIXTURES")?.let {File(it)}
        assumeTrue(manifest?.isFile==true)
        val data=JSONObject(manifest!!.readText());val output=File(data.getString("output"));output.mkdirs()
        val result=JSONArray();val inputs=data.getJSONArray("inputs")
        val ids=(0 until inputs.length()).map {inputs.getJSONObject(it).getString("id")}
        require(ids.size==ids.toSet().size&&ids.all {it.matches(Regex("[A-Za-z0-9_-]{1,64}"))})
        for(i in 0 until inputs.length()) {
            val item=inputs.getJSONObject(i);val input=File(item.getString("file"));val before=digest(input);val pcm=read(input)
            val text=item.getString("text");val language=item.optString("language","zh")
            val timings=ArrayList<Double>();var firstPassMs=0.0;var stats: NarrationRhythm.Stats?=null;var firstInput=0;var rendered=listOf<FloatArray>()
            repeat(12){run->
                val chunks=ArrayList<FloatArray>();var submitted=0;var first=-1
                val start=System.nanoTime()
                val rhythm=NarrationRhythm(text,language){if(first<0)first=submitted;chunks+=it}
                var at=0
                while(at<pcm.size){val end=minOf(at+30720,pcm.size);submitted=end;rhythm.append(pcm.copyOfRange(at,end));at=end}
                rhythm.finish();val elapsed=(System.nanoTime()-start)/1e6
                if(run==0)firstPassMs=elapsed
                if(run>=2)timings+=elapsed
                if(run==11){stats=rhythm.stats;rendered=chunks;firstInput=first}
                rhythm.close()
            }
            val s=stats!!;val target=File(output,item.getString("id")+".wav")
            write(target,rendered);assertEquals(before,digest(input))
            assertTrue(s.maxBufferedSamples<200000);assertTrue(rendered.all {it.all {v->v.isFinite()}})
            val sorted=timings.sorted()
            result.put(JSONObject().put("id",item.getString("id")).put("input_seconds",pcm.size/96000.0).put("output_seconds",s.outputSamples/96000.0)
                .put("pause_removed_ms",s.removedPauseSamples/96.0).put("drag_removed_ms",s.removedDragSamples/96.0).put("local_tempo",s.localTempo)
                .put("max_buffered_samples",s.maxBufferedSamples).put("first_output_after_input_seconds",firstInput/96000.0)
                .put("median_process_ms",(sorted[4]+sorted[5])/2).put("maximum_process_ms",sorted.last())
                .put("first_pass_process_ms",firstPassMs)
                .put("source_unchanged",true).put("output_file",target.name))
        }
        File(output,"results.json").writeText(JSONObject().put("environment","Desktop JVM; no native model inference or AudioTrack")
            .put("java",System.getProperty("java.version")).put("samples",result).toString(2))
    }
}
