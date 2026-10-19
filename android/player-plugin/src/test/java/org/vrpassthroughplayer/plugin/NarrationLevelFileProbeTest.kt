package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assume.assumeTrue
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Opt-in audio evidence; never includes personal recordings in test assets. */
class NarrationLevelFileProbeTest {
    private fun read(file: File): FloatArray {
        val bytes=file.readBytes();val b=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        require(String(bytes,0,4)=="RIFF"&&String(bytes,36,4)=="data"&&b.getInt(40)==bytes.size-44)
        require(b.getShort(22).toInt()==2&&b.getInt(24)==48000&&b.getShort(34).toInt()==16)
        b.position(44);return FloatArray((bytes.size-44)/2){b.short/32768f}
    }
    private fun write(file: File,chunks: List<FloatArray>){
        val count=chunks.sumOf {it.size};val b=ByteBuffer.allocate(44+count*2).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt(36+count*2).put("WAVEfmt ".toByteArray()).putInt(16)
            .putShort(1).putShort(2).putInt(48000).putInt(192000).putShort(4).putShort(16).put("data".toByteArray()).putInt(count*2)
        chunks.forEach {it.forEach {x->b.putShort((x*32767).toInt().coerceIn(-32767,32767).toShort())}}
        file.writeBytes(b.array())
    }
    @Test fun processExplicitPrivateFixtureCopies(){
        val manifest=System.getenv("THRU3D_LEVEL_FIXTURES")?.let {File(it)};assumeTrue(manifest?.isFile==true)
        val j=JSONObject(manifest!!.readText());val folder=File(j.getString("output"));folder.mkdirs()
        val result=JSONArray();val rows=j.getJSONArray("inputs")
        for(i in 0 until rows.length()){
            val row=rows.getJSONObject(i);val id=row.getString("id");require(id.matches(Regex("[A-Za-z0-9_-]+")))
            val input=File(row.getString("file"));val hash=PersonalVoiceStore.hash(input);val pcm=read(input)
            val output=File(folder,"$id.wav");val info=JSONObject().put("id",id).put("input_samples",pcm.size)
            val started=System.nanoTime()
            if(row.optBoolean("reference")){
                val prepared=VoiceReferencePcm.prepare(pcm);VoiceReferencePcm.write(output,prepared.pcm)
                info.put("input_db",prepared.inputDb).put("output_db",prepared.outputDb).put("gain_db",prepared.gainDb)
                    .put("crest_db",prepared.crestDb).put("target_db",prepared.targetDb)
            }else{
                val chunks=ArrayList<FloatArray>();var first=-1;var submitted=0
                NarrationLevel {if(first<0)first=submitted;chunks+=it}.use {level->
                    val rhythm=if(row.has("text"))NarrationRhythm(row.getString("text"),row.optString("language","zh")){level.append(it)} else null
                    try {
                        var at=0;while(at<pcm.size){val end=minOf(at+30720,pcm.size);submitted=end;val chunk=pcm.copyOfRange(at,end)
                            if(rhythm!=null)rhythm.append(chunk) else level.append(chunk);at=end}
                        rhythm?.finish();level.finish()
                    } finally {rhythm?.close()}
                    info.put("gain_db",level.stats.gainDb).put("initial_gain_db",level.stats.initialGainDb)
                        .put("limited_frames",level.stats.limitedFrames).put("max_buffer_samples",level.stats.maxBufferedSamples)
                        .put("first_output_after_input_seconds",first/96000.0)
                    val count=chunks.sumOf {it.size};info.put("output_samples",count)
                    if(rhythm==null)assertEquals(pcm.size,count) else assertTrue(count in 1..pcm.size)
                    assertTrue(chunks.all {chunk->chunk.all {x->x.isFinite()&&kotlin.math.abs(x)<=.94001f}})
                };write(output,chunks)
            }
            info.put("process_ms",(System.nanoTime()-started)/1e6);result.put(info)
            assertEquals(hash,PersonalVoiceStore.hash(input))
        }
        File(folder,"results.json").writeText(JSONObject().put("samples",result).toString(2))
    }
}
