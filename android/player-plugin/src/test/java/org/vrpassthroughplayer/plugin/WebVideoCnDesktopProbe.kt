package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.json.JSONArray
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Private stdin only. Exercises current HLS discovery and the real production loopback lease. */
object WebVideoCnDesktopProbe {
    private data class Output(val code: Int, val bytes: ByteArray, val diagnostics: JSONObject)
    private fun run(arguments: List<String>, limit: Int = 65536): Output {
        val process = ProcessBuilder(arguments).start()
        val reader = Executors.newFixedThreadPool(2)
        val output = reader.submit<ByteArray> { process.inputStream.use { it.readNBytes(limit + 1) } }
        val errors = reader.submit<ByteArray> { process.errorStream.use { input ->
            val prefix = java.io.ByteArrayOutputStream();val buffer = ByteArray(8192)
            while (true) { val n = input.read(buffer);if (n < 0) break;if (prefix.size() < 65536) prefix.write(buffer,0,minOf(n,65536-prefix.size())) }
            prefix.toByteArray()
        } }
        return try {
            check(process.waitFor(40, TimeUnit.SECONDS)) { "Decode budget" }
            val bytes = output.get(3, TimeUnit.SECONDS);check(bytes.size <= limit)
            val error = errors.get(3,TimeUnit.SECONDS).toString(Charsets.UTF_8).lowercase()
            // Keep only categories and numeric statuses. FFmpeg's original error text
            // can contain signed child URLs, so it never enters a report or log.
            val status = Regex("(?:http error|server returned)[: ]+([0-9]{3})").findAll(error).map { it.groupValues[1].toInt() }.distinct().toList()
            val flags = listOf("invalid data","input/output error","could not seek","end of file","failed to open segment","error when loading first segment","unable to seek").filter { it in error }
            Output(process.exitValue(),bytes,JSONObject().put("http_status",org.json.JSONArray(status)).put("categories",org.json.JSONArray(flags)))
        } finally { process.destroyForcibly(); reader.shutdownNow() }
    }
    @JvmStatic fun main(args: Array<String>) {
        val result = JSONObject().put("passed",false).put("scope","production browser capture and bounded local decoding; no Android/UI claim")
        var stage = "input"
        try {
            val bytes = System.`in`.readNBytes(256 * 1024 + 1);require(bytes.size <= 256 * 1024)
            val media = JSONObject(bytes.toString(Charsets.UTF_8))
            val weibo = media.optBoolean("weibo_enabled")
            val tencent = media.optBoolean("tencent_ready") && media.optJSONObject("tencent") != null
            val mango = media.optBoolean("mango_ready") && media.optJSONObject("mango") != null
            val youku = media.optBoolean("youku_ready") && media.optJSONObject("youku") != null
            if (youku) media.put("youku_enabled",true).put("capture_identity","desktop-selected")
            if (mango) media.put("mango_enabled",true).put("capture_identity","desktop-selected")
            if (tencent) media.put("tencent_enabled",true).put("capture_identity","desktop-selected")
            val page = if (weibo) WebVideoWeiboCapture.page(media.getString("frame"),media) ?: error("Weibo identity unavailable")
                else if (youku) WebVideoYoukuCapture.page(media.getString("frame"),media) ?: error("Youku identity unavailable")
                else if (mango) WebVideoMangoCapture.page(media.getString("frame"),media) ?: error("Mango identity unavailable")
                else if (tencent) WebVideoTencentCapture.page(media.getString("frame"),media) ?: error("Tencent identity unavailable")
                else WebVideoPage.parse(media.getString("frame"))
            require(page.site in setOf("mgtv","youku","weibo","tencent"))
            require(!media.optBoolean("protected") && (weibo || tencent || media.optBoolean("blob")))
            if (weibo) { result.put("bridge_metadata",WebBrowserWeibo.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata")) }
            if (tencent) { result.put("bridge_metadata",WebBrowserTencent.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata")) }
            if (mango) { result.put("entry_enabled",WebBrowserMango.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserMango.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata")) }
            if (youku) { result.put("entry_enabled",WebBrowserYouku.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserYouku.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata")) }
            val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(40)
            val reads=JSONArray();result.put("network_reads",reads)
            val capture=WebVideoNetworkCapture({uri,headers,prefix ->
                val item=JSONObject().put("prefix",prefix)
                if(reads.length()<12)reads.put(item)
                try {
                    RemoteMediaHttp().use { http -> WebVideoBrowserResourceReader.read(uri,headers,prefix,http) { check(System.nanoTime()<deadline) } }.also { (_,body) ->
                        item.put("bytes",body.size)
                        if(!prefix && body.take(7).toByteArray().toString(Charsets.UTF_8)=="#EXTM3U") {
                            // Tag names only; no attribute values, URLs, hashes or response text.
                            val tags=body.toString(Charsets.UTF_8).lineSequence().filter { it.contains("URI=") }
                                .map { Regex("^(#[A-Za-z0-9-]{1,64})(?=:|$)").find(it)?.groupValues?.get(1) ?: "other" }.distinct().take(32).toList()
                            item.put("uri_tags",JSONArray(tags))
                            val vendor=body.toString(Charsets.UTF_8).lineSequence().filter { it.startsWith("#EXT-MGTV-X-MAP:") }.take(4).map { line ->
                                val value=Regex("URI=\"([^\"]+)\"").find(line)?.groupValues?.get(1).orEmpty()
                                val parsed=runCatching { java.net.URI(value) }.getOrNull()
                                JSONObject().put("length",value.length).put("scheme",parsed?.scheme?.takeIf { it.matches(Regex("[A-Za-z0-9+-]{1,24}")) } ?: "relative_or_invalid")
                                    .put("host",parsed?.host!=null).put("fragment",parsed?.fragment!=null).put("userinfo",parsed?.rawUserInfo!=null)
                                    .put("base64_data",value.startsWith("data:") && value.substringBefore(',').endsWith(";base64"))
                            }.toList()
                            item.put("vendor_map_shape",JSONArray(vendor))
                        }
                        if(prefix) (WebVideoContainer.parse(body) ?: WebVideoContainer.transportStream(body))?.let {
                            item.put("width",it.width).put("height",it.height).put("video",it.video).put("audio",it.audio)
                        }
                    }
                } catch(error:Exception) {
                    item.put("error_type",error.javaClass.simpleName)
                    Regex("(?:HTTP|response code:?)\\s*([0-9]{3})",RegexOption.IGNORE_CASE).find(error.message.orEmpty())?.groupValues?.get(1)?.toIntOrNull()?.let { item.put("http_status",it) }
                    throw error
                }
            },{true})
            stage="selection"
            if(tencent) {
                val data=media.getJSONObject("tencent")
                result.put("selection_input",JSONObject().put("candidate_bound",WebVideoTencentCapture.candidate(page,media)!=null)
                    .put("observed_count",WebBrowserNetworkMedia.candidates(media,true).length())
                    .put("dom_duration",media.optDouble("duration")).put("metadata_duration",data.optDouble("duration"))
                    .put("content_duration",data.optDouble("content_duration"))
                    .put("playlist_duration",data.optString("playlist").lineSequence().filter { it.startsWith("#EXTINF:") }.sumOf { it.substringAfter(':').substringBefore(',').toDouble() }))
            }
            val info=(if(weibo) WebVideoWeiboCapture.resolve(page,media,capture) else if(tencent) WebVideoTencentCapture.resolve(page,media,capture) else if(mango) WebVideoMangoCapture.resolve(page,media,capture) else if(youku) WebVideoYoukuCapture.resolve(page,media,capture) else capture.resolveCurrent(page,media)) ?: error("Current stream not bound")
            val selected=WebVideoFormats.select(page,info){true}
            result.put("site",page.site).put("width",selected.video.width).put("height",selected.video.height)
                .put("video_codec",selected.video.videoCodec).put("audio_codec",selected.audio?.audioCodec ?: selected.video.audioCodec)
                .put("transport",selected.video.transport).put("current_size",selected.video.width==media.optInt("width") && selected.video.height==media.optInt("height"))
            check(result.getBoolean("current_size") && (weibo || tencent || selected.video.transport=="hls"))
            stage="lease"
            LocalStreamServer().use { server -> WebVideoStreams { server }.use { streams ->
                val local=streams.prepare(selected)
                val audio=streams.audio(page.url).firstOrNull()?.location
                stage="probe"
                val probe=run(listOf("ffprobe","-v","error","-show_entries","stream=codec_type,codec_name,width,height,sample_rate,channels:format=duration,start_time","-of","json",local))
                check(probe.code==0)
                val tracks=JSONObject(probe.bytes.toString(Charsets.UTF_8)).getJSONArray("streams")
                val list=(0 until tracks.length()).map{tracks.getJSONObject(it)}
                val video=list.first{it.optString("codec_type")=="video"}
                val sound=list.firstOrNull{it.optString("codec_type")=="audio"}
                result.put("streams",tracks)
                result.put("format_timing",JSONObject(probe.bytes.toString(Charsets.UTF_8)).optJSONObject("format"))
                check(video.getInt("width")==media.optInt("width") && video.getInt("height")==media.optInt("height"))
                check(sound!=null || audio!=null)
                val duration=media.getDouble("duration")
                val start=media.optDouble("time").coerceIn(0.0,maxOf(0.0,duration-4.0))
                if (tencent && selected.video.transport == "hls") {
                    val lines = java.net.URI(local).toURL().openStream().use { it.readNBytes(256*1024) }.toString(Charsets.UTF_8).lines()
                    val parts = ArrayList<Triple<Int,Double,String>>();var position=0.0;var length=0.0
                    for (line in lines) {
                        if (line.startsWith("#EXTINF:")) length=line.substringAfter(':').substringBefore(',').toDouble()
                        else if(line.startsWith("http")) {parts.add(Triple(parts.size,position,line));position+=length}
                    }
                    val timing = org.json.JSONArray()
                    for (at in listOf(0.0,start,minOf(start+20,maxOf(0.0,duration-4)))) {
                        val part = parts.lastOrNull { it.second <= at } ?: continue
                        val probePart=run(listOf("ffprobe","-v","error","-show_entries","stream=index,id,codec_name,codec_type,width,height,start_time,duration:format=start_time,duration","-of","json",part.third))
                        val keyframes=run(listOf("ffprobe","-v","error","-select_streams","v:0","-show_frames","-show_entries","frame=pts_time,key_frame","-of","json",part.third))
                        val frameList=runCatching { JSONObject(keyframes.bytes.toString(Charsets.UTF_8)).getJSONArray("frames") }.getOrNull()
                        val pts=(0 until (frameList?.length() ?: 0)).map { frameList!!.getJSONObject(it) }
                        val partInfo=runCatching { JSONObject(probePart.bytes.toString(Charsets.UTF_8)) }.getOrNull()
                        timing.put(JSONObject().put("index",part.first).put("timeline_start",part.second).put("requested_at",at).put("exit",probePart.code)
                            .put("timing",partInfo?.optJSONObject("format")).put("tracks",partInfo?.optJSONArray("streams"))
                            .put("video_frames",pts.size).put("key_pts",org.json.JSONArray(pts.filter { it.optInt("key_frame")==1 }.map { it.optString("pts_time") })))
                    }
                    result.put("segment_timing",timing)
                }
                fun decode(at: Double): Boolean {
                    // CLI input seeking can discard up to the *next* HLS keyframe.
                    // Keep a bounded preroll, then accurately trim the same requested
                    // target; a three-second sample must not end inside that GOP gap.
                    val preroll = if (selected.video.transport == "hls") minOf(20.0,at) else 0.0
                    val command=mutableListOf("ffmpeg","-v","error","-progress","pipe:1","-nostats","-ss",(at-preroll).toString(),"-i",local)
                    if(audio!=null)command+=listOf("-ss",(at-preroll).toString(),"-i",audio)
                    if(preroll>0)command+=listOf("-ss",preroll.toString())
                    command+=listOf("-t","3","-map","0:v:0","-map",if(audio==null)"0:a:0" else "1:a:0","-f","null","-")
                    val output=run(command)
                    val frames=Regex("(?m)^frame=([0-9]+)").findAll(output.bytes.toString(Charsets.UTF_8)).map{it.groupValues[1].toInt()}.maxOrNull() ?: 0
                    result.put(if(at==start)"frames" else "seek_frames",frames)
                    result.put(if(at==start)"decode_exit" else "seek_exit",output.code)
                        .put(if(at==start)"decode_diagnostics" else "seek_diagnostics",output.diagnostics)
                    return output.code==0 && frames>=8
                }
                stage="joint_decode";result.put("decoded",decode(start)).put("start_seconds",start)
                stage="audio_decode"
                val soundAt=minOf(maxOf(start,20.0),maxOf(0.0,duration-4.0))
                val audioPreroll = if (selected.video.transport == "hls") minOf(20.0,soundAt) else 0.0
                val pcm=run(listOf("ffmpeg","-v","error","-ss",(soundAt-audioPreroll).toString(),"-i",audio ?: local,"-ss",audioPreroll.toString(),"-t","3","-map","0:a:0","-vn","-ac","2","-ar","48000","-f","s16le","pipe:1"),1024*1024)
                result.put("audio_samples_48k_stereo",pcm.bytes.size/4).put("audio_nonzero",pcm.bytes.any{it!=0.toByte()})
                    .put("audio_seconds",soundAt)
                stage="seek_decode";result.put("seeked",decode(minOf(start+20.0,maxOf(0.0,duration-4.0))))
                streams.release(local);result.put("lease_closed",!server.hasSource(local))
                result.put("passed",result.getBoolean("decoded") && result.getBoolean("seeked") && pcm.code==0 && pcm.bytes.size>=48000*4*2 && result.getBoolean("audio_nonzero") && result.getBoolean("lease_closed"))
            } }
        } catch(error: Exception) {
            result.put("stage",stage).put("error_type",error.javaClass.simpleName)
            // Source locations only: exception messages can contain signed media URLs.
            result.put("error_frames",JSONArray(error.stackTrace.filter { it.className.startsWith("org.vrpassthroughplayer.plugin.") }.take(6).map {
                JSONObject().put("class",it.className.substringAfterLast('.')).put("method",it.methodName).put("line",it.lineNumber)
            }))
            if(error is MediaServerFailure)result.put("http_status",error.httpStatus).put("transport_error",error.transportError)
        }
        println(result.toString())
    }
}
