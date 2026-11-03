package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Private stdin only. Exercises current HLS discovery and the real production loopback lease. */
object WebVideoCnDesktopProbe {
    private data class Output(val code: Int, val bytes: ByteArray)
    private fun run(arguments: List<String>, limit: Int = 65536): Output {
        val sink = File(if (System.getProperty("os.name").startsWith("Windows")) "NUL" else "/dev/null")
        val process = ProcessBuilder(arguments).redirectError(sink).start()
        val reader = Executors.newSingleThreadExecutor()
        val output = reader.submit<ByteArray> { process.inputStream.use { it.readNBytes(limit + 1) } }
        return try {
            check(process.waitFor(40, TimeUnit.SECONDS)) { "Decode budget" }
            val bytes = output.get(3, TimeUnit.SECONDS);check(bytes.size <= limit)
            Output(process.exitValue(),bytes)
        } finally { process.destroyForcibly(); reader.shutdownNow() }
    }
    @JvmStatic fun main(args: Array<String>) {
        val result = JSONObject().put("passed",false).put("scope","production current HLS discovery and bounded local decoding; no Android/UI claim")
        var stage = "input"
        try {
            val bytes = System.`in`.readNBytes(256 * 1024 + 1);require(bytes.size <= 256 * 1024)
            val media = JSONObject(bytes.toString(Charsets.UTF_8))
            val page = WebVideoPage.parse(media.getString("frame"));require(page.site in setOf("mgtv","youku"))
            require(!media.optBoolean("protected") && media.optBoolean("blob"))
            val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(40)
            val capture=WebVideoNetworkCapture({uri,headers,prefix ->
                RemoteMediaHttp().use { http -> WebVideoBrowserResourceReader.read(uri,headers,prefix,http) { check(System.nanoTime()<deadline) } }
            },{true})
            stage="selection"
            val info=capture.resolveCurrent(page,media) ?: error("Current HLS not bound")
            val selected=WebVideoFormats.select(page,info){true}
            result.put("site",page.site).put("width",selected.video.width).put("height",selected.video.height)
                .put("video_codec",selected.video.videoCodec).put("audio_codec",selected.audio?.audioCodec ?: selected.video.audioCodec)
                .put("transport",selected.video.transport).put("current_size",selected.video.width==media.optInt("width") && selected.video.height==media.optInt("height"))
            check(result.getBoolean("current_size") && selected.video.transport=="hls")
            stage="lease"
            LocalStreamServer().use { server -> WebVideoStreams { server }.use { streams ->
                val local=streams.prepare(selected)
                val audio=streams.audio(page.url).firstOrNull()?.location
                stage="probe"
                val probe=run(listOf("ffprobe","-v","error","-show_entries","stream=codec_type,codec_name,width,height,sample_rate,channels","-of","json",local))
                check(probe.code==0)
                val tracks=JSONObject(probe.bytes.toString(Charsets.UTF_8)).getJSONArray("streams")
                val list=(0 until tracks.length()).map{tracks.getJSONObject(it)}
                val video=list.first{it.optString("codec_type")=="video"}
                val sound=list.firstOrNull{it.optString("codec_type")=="audio"}
                result.put("streams",tracks)
                check(video.getInt("width")==media.optInt("width") && video.getInt("height")==media.optInt("height"))
                check(sound!=null || audio!=null)
                val duration=media.getDouble("duration")
                val start=media.optDouble("time").coerceIn(0.0,maxOf(0.0,duration-4.0))
                fun decode(at: Double): Boolean {
                    val command=mutableListOf("ffmpeg","-v","error","-progress","pipe:1","-nostats","-ss",at.toString(),"-i",local)
                    if(audio!=null)command+=listOf("-ss",at.toString(),"-i",audio)
                    command+=listOf("-t","3","-map","0:v:0","-map",if(audio==null)"0:a:0" else "1:a:0","-f","null","-")
                    val output=run(command)
                    val frames=Regex("(?m)^frame=([0-9]+)").findAll(output.bytes.toString(Charsets.UTF_8)).map{it.groupValues[1].toInt()}.maxOrNull() ?: 0
                    result.put(if(at==start)"frames" else "seek_frames",frames)
                    return output.code==0 && frames>=8
                }
                stage="joint_decode";result.put("decoded",decode(start)).put("start_seconds",start)
                stage="audio_decode"
                val soundAt=minOf(maxOf(start,20.0),maxOf(0.0,duration-4.0))
                val pcm=run(listOf("ffmpeg","-v","error","-ss",soundAt.toString(),"-i",audio ?: local,"-t","3","-map","0:a:0","-vn","-ac","2","-ar","48000","-f","s16le","pipe:1"),1024*1024)
                result.put("audio_samples_48k_stereo",pcm.bytes.size/4).put("audio_nonzero",pcm.bytes.any{it!=0.toByte()})
                    .put("audio_seconds",soundAt)
                stage="seek_decode";result.put("seeked",decode(minOf(start+20.0,maxOf(0.0,duration-4.0))))
                streams.release(local);result.put("lease_closed",!server.hasSource(local))
                result.put("passed",result.getBoolean("decoded") && result.getBoolean("seeked") && pcm.code==0 && pcm.bytes.size>=48000*4*2 && result.getBoolean("audio_nonzero") && result.getBoolean("lease_closed"))
            } }
        } catch(error: Exception) {
            result.put("stage",stage).put("error_type",error.javaClass.simpleName)
            if(error is MediaServerFailure)result.put("http_status",error.httpStatus).put("transport_error",error.transportError)
        }
        println(result.toString())
    }
}
