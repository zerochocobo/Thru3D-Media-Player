package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.json.JSONArray
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Private stdin only. Exercises current HLS discovery and the real production loopback lease. */
object WebVideoCnDesktopProbe {
    /** Local failed-file diagnosis only. Fixed box names, lengths and errors;
     * no addresses, headers, response text or file bytes leave this process. */
    private fun archiveHeaderShape(uri: java.net.URI,headers: Map<String,String>,prefix: ByteArray,check: () -> Unit): JSONObject {
        val result=JSONObject();val reads=JSONArray();result.put("reads",reads)
        val known=setOf("ftyp","moov","mdat","free","skip","wide","sidx","moof","pssh")
        fun uint(data: ByteArray,at: Int,count: Int): Long {var n=0L;repeat(count){require(n<=Long.MAX_VALUE ushr 8);n=(n shl 8) or (data[at+it].toLong() and 255)};return n}
        try {RemoteMediaHttp().use {http ->
            val first=http.open(uri,"bytes=0-15",headers)
            val total: Long;val finalUri: java.net.URI;val etag: String?
            try {
                first.readTimeout=5000;require(first.responseCode==206)
                total=Regex("bytes 0-15/([0-9]+)").matchEntire(first.getHeaderField("Content-Range").orEmpty())!!.groupValues[1].toLong()
                finalUri=first.url.toURI();etag=first.getHeaderField("ETag")?.takeIf{!it.startsWith("W/")}
            }finally{http.release(first)}
            result.put("file_bytes",total)
            val inspected=WebVideoMp4Header.inspect(object:Mp4InterleavePolicy.Reader {
                override val size=total
                override fun read(offset: Long,length: Int): ByteArray {
                    check();require(reads.length()<16)
                    val row=JSONObject().put("offset",offset).put("length",length);reads.put(row)
                    val connection=http.open(uri,"bytes=$offset-${offset+length-1}",headers)
                    try {
                        connection.readTimeout=5000
                        row.put("status",connection.responseCode)
                        require(connection.responseCode==206 && connection.url.toURI()==finalUri)
                        val exact=connection.getHeaderField("Content-Range")=="bytes $offset-${offset+length-1}/$total"
                        row.put("exact_range",exact);require(exact)
                        require(etag==null||connection.getHeaderField("ETag")==etag)
                        val bytes=connection.inputStream.use{it.readNBytes(length+1)};require(bytes.size==length)
                        if(length==16){val type=String(bytes,4,4,Charsets.US_ASCII);row.put("box",if(type in known)type else "other")
                            val size32=uint(bytes,0,4);row.put("box_bytes",if(size32==1L)uint(bytes,8,8) else size32)}
                        return bytes
                    }finally{http.release(connection)}
                }
            },prefix)
            result.put("header_bytes",inspected.size).put("parsed",WebVideoContainer.parse(inspected)!=null)
        }}catch(error:Exception){result.put("error_type",error.javaClass.simpleName)}
        return result
    }
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
            if(args.contentEquals(arrayOf("--instagram-identity"))){
                val before=media.getJSONObject("before");val after=media.getJSONObject("after")
                val page=before.getString("frame")
                val data=WebBrowserInstagram.metadata(before,page)
                println(JSONObject().put("identity_matches",data!=null && WebBrowserInstagram.matchesIdentity(after,WebBrowserInstagram.identity(data!!),page)))
                return
            }
            val douyinResearch=args.contentEquals(arrayOf("--rendered-card-research"))
            require(args.isEmpty() || douyinResearch)
            val douyin=media.optBoolean("douyin_ready") && media.optJSONObject("douyin")!=null
            require(douyin==douyinResearch)
            if(douyin) {
                media.put("douyin_enabled",true)
                require(media.optBoolean("douyin_enabled") && WebBrowserDouyin.renderedId(media)!=null)
                result.put("beta_default_enabled",WebBrowserDouyin.enabled(media.getString("frame"))).put("rendered_card_research",true)
            }
            val weibo = media.optBoolean("weibo_enabled")
            val bilibili = media.optBoolean("bilibili_ready") && media.optJSONObject("bilibili") != null
            if (bilibili) media.put("bilibili_enabled", true)
            val tencent = media.optBoolean("tencent_ready") && media.optJSONObject("tencent") != null
            val mango = media.optBoolean("mango_ready") && media.optJSONObject("mango") != null
            val youku = media.optBoolean("youku_ready") && media.optJSONObject("youku") != null
            val twitch=media.optBoolean("twitch_ready") && media.optJSONObject("twitch")!=null
            val archive=media.optBoolean("archive_ready") && media.optJSONObject("archive")!=null
            val odysee=media.optBoolean("odysee_ready") && media.optJSONObject("odysee")!=null
            val streamable=media.optBoolean("streamable_ready") && media.optJSONObject("streamable")!=null
            val reddit=media.optBoolean("reddit_ready") && media.optJSONObject("reddit")!=null
            val naver=media.optBoolean("naver_ready") && media.optJSONObject("naver")!=null
            if(twitch)media.put("twitch_enabled",true).put("capture_identity","desktop-selected")
            if(archive)media.put("archive_enabled",true).put("capture_identity","desktop-selected")
            if(odysee)media.put("odysee_enabled",true).put("capture_identity","desktop-selected")
            if(streamable)media.put("streamable_enabled",true).put("capture_identity","desktop-selected")
            if(reddit)media.put("reddit_enabled",true).put("capture_identity","desktop-selected")
            if(naver){media.put("naver_enabled",true).put("capture_identity","desktop-selected")
                result.put("naver_checks",WebBrowserNaver.diagnostics(media,media.getString("frame")))}
            val tiktok=media.optBoolean("tiktok_ready") && media.optJSONObject("tiktok")!=null
            if(tiktok)media.put("tiktok_enabled",true).put("capture_identity","desktop-selected")
            val instagram=media.optBoolean("instagram_ready") && media.optJSONObject("instagram")!=null
            if(instagram)media.put("instagram_enabled",true).put("capture_identity","desktop-selected")
            val ted=media.optBoolean("ted_ready") && media.optJSONObject("ted")!=null
            if(ted)media.put("ted_enabled",true).put("capture_identity","desktop-selected")
            val redbull=media.optBoolean("redbull_ready") && media.optJSONObject("redbull")!=null
            if(redbull)media.put("redbull_enabled",true).put("capture_identity","desktop-selected")
            val dailymotion=media.optBoolean("dailymotion_ready") && media.optJSONObject("dailymotion")!=null
            if(dailymotion)media.put("dailymotion_enabled",true).put("capture_identity","desktop-selected")
            val niconico=media.optBoolean("niconico_ready") && media.optJSONObject("niconico")!=null
            if(niconico)media.put("niconico_enabled",true).put("capture_identity","desktop-selected")
            val iqiyi = media.optBoolean("iqiyi_ready") && media.optJSONObject("iqiyi") != null
            if (iqiyi) media.put("iqiyi_enabled",true).put("capture_identity","desktop-selected")
            if (youku) media.put("youku_enabled",true).put("capture_identity","desktop-selected")
            if (mango) media.put("mango_enabled",true).put("capture_identity","desktop-selected")
            if (tencent) media.put("tencent_enabled",true).put("capture_identity","desktop-selected")
            val page = if (douyin) WebVideoDouyinCapture.selectedPage(media) ?: error("Douyin rendered identity unavailable")
                else if (weibo) WebVideoWeiboCapture.page(media.getString("frame"),media) ?: error("Weibo identity unavailable")
                else if (iqiyi) WebVideoIqiyiCapture.page(media.getString("frame"),media) ?: error("iQIYI identity unavailable")
                else if(twitch)WebVideoTwitchCapture.page(media.getString("frame"),media) ?: error("Twitch identity unavailable")
                else if(archive)WebVideoArchiveCapture.page(media.getString("frame"),media) ?: error("Archive identity unavailable")
                else if(odysee)WebVideoOdyseeCapture.page(media.getString("frame"),media) ?: error("Odysee identity unavailable")
                else if(streamable)WebVideoStreamableCapture.page(media.getString("frame"),media) ?: error("Streamable identity unavailable")
                else if(reddit)WebVideoRedditCapture.page(media.getString("frame"),media) ?: error("Reddit identity unavailable")
                else if(naver)WebVideoNaverCapture.page(media.getString("frame"),media) ?: error("Naver identity unavailable")
                else if(tiktok)WebVideoTikTokCapture.page(media.getString("frame"),media) ?: error("TikTok identity unavailable")
                else if(instagram)WebVideoInstagramCapture.page(media.getString("frame"),media) ?: error("Instagram identity unavailable")
                else if(ted)WebVideoTedCapture.page(media.getString("frame"),media) ?: error("Ted identity unavailable")
                else if(redbull)WebVideoRedBullCapture.page(media.getString("frame"),media) ?: error("Red Bull identity unavailable")
                else if(dailymotion)WebVideoDailymotionCapture.page(media.getString("dailymotion_owner"),media) ?: error("Dailymotion identity unavailable")
                else if(niconico)WebVideoNiconicoCapture.page(media.getString("frame"),media) ?: error("Niconico identity unavailable")
                else if (youku) WebVideoYoukuCapture.page(media.getString("frame"),media) ?: error("Youku identity unavailable")
                else if (mango) WebVideoMangoCapture.page(media.getString("frame"),media) ?: error("Mango identity unavailable")
                else if (tencent) WebVideoTencentCapture.page(media.getString("frame"),media) ?: error("Tencent identity unavailable")
                else WebVideoPage.parse(media.getString("frame"))
            require(page.site in setOf("bilibili","mgtv","youku","weibo","tencent","iqiyi","douyin","niconico","twitch","tiktok","ted","instagram","dailymotion","redbull","naver","reddit","streamable","archive","odysee"))
            require(!media.optBoolean("protected") && (bilibili || douyin || weibo || tencent || twitch || naver || reddit || streamable || archive || odysee || tiktok || instagram || media.optBoolean("blob")))
            if (douyin) { result.put("bridge_metadata",WebBrowserDouyin.metadata(media,media.getString("frame"),true)!=null);check(result.getBoolean("bridge_metadata")) }
            if (weibo) { result.put("bridge_metadata",WebBrowserWeibo.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata")) }
            if (tencent) { result.put("bridge_metadata",WebBrowserTencent.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata")) }
            if (mango) { result.put("entry_enabled",WebBrowserMango.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserMango.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata")) }
            if (youku) { result.put("entry_enabled",WebBrowserYouku.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserYouku.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata")) }
            if(twitch){result.put("entry_enabled",WebBrowserTwitch.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserTwitch.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata"))}
            if(streamable){result.put("entry_enabled",WebBrowserStreamable.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserStreamable.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata"))}
            if(reddit){result.put("entry_enabled",WebBrowserReddit.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserReddit.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata"))}
            if(naver){result.put("entry_enabled",WebBrowserNaver.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserNaver.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata"))}
            if(archive){result.put("entry_enabled",WebBrowserArchive.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserArchive.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata"))}
            if(odysee){result.put("entry_enabled",WebBrowserOdysee.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserOdysee.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata"))}
            if(streamable){result.put("entry_enabled",WebBrowserStreamable.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserStreamable.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata"))}
            if(tiktok){result.put("entry_enabled",WebBrowserTikTok.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserTikTok.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata"))}
            if(instagram){result.put("entry_enabled",WebBrowserInstagram.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserInstagram.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata"))}
            if(ted){result.put("entry_enabled",WebBrowserTed.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserTed.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata"))}
            if(redbull){result.put("entry_enabled",WebBrowserRedBull.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserRedBull.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata"))}
            if(dailymotion){result.put("entry_enabled",WebBrowserDailymotion.enabled(media.getString("dailymotion_owner")))
                result.put("bridge_metadata",WebBrowserDailymotion.metadata(media,media.getString("dailymotion_owner"))!=null);check(result.getBoolean("bridge_metadata"))}
            if(niconico){result.put("entry_enabled",WebBrowserNiconico.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserNiconico.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata"))}
            if (iqiyi) { result.put("entry_enabled",WebBrowserIqiyi.enabled(media.getString("frame")))
                result.put("bridge_metadata",WebBrowserIqiyi.metadata(media,media.getString("frame"))!=null);check(result.getBoolean("bridge_metadata")) }
            val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(40)
            val reads=JSONArray();result.put("network_reads",reads)
            val capture=WebVideoNetworkCapture({uri,headers,prefix ->
                val item=JSONObject().put("prefix",prefix)
                if(reads.length()<12)reads.put(item)
                try {
                    RemoteMediaHttp().use { http -> WebVideoBrowserResourceReader.read(uri,headers,prefix,http) { check(System.nanoTime()<deadline) } }.also { (_,body) ->
                        item.put("bytes",body.size)
                        if(archive && prefix && WebVideoContainer.parse(body)==null)
                            item.put("archive_header_shape",archiveHeaderShape(uri,headers,body){check(System.nanoTime()<deadline)})
                        if(!prefix && body.take(7).toByteArray().toString(Charsets.UTF_8)=="#EXTM3U") {
                            // Tag names only; no attribute values, URLs, hashes or response text.
                            val tags=body.toString(Charsets.UTF_8).lineSequence().filter { it.contains("URI=") }
                                .map { Regex("^(#[A-Za-z0-9-]{1,64})(?=:|$)").find(it)?.groupValues?.get(1) ?: "other" }.distinct().take(32).toList()
                            item.put("uri_tags",JSONArray(tags))
                            if(niconico && body.toString(Charsets.UTF_8).contains("#EXT-X-STREAM-INF:")) {
                                val refs=body.toString(Charsets.UTF_8).lineSequence().map(String::trim).flatMap { line ->
                                    if(line.isNotEmpty()&&!line.startsWith('#'))sequenceOf(line)
                                    else Regex("URI=\"([^\"]+)\"").findAll(line).map { it.groupValues[1] }
                                }.take(48).mapNotNull { runCatching { uri.resolve(it) }.getOrNull() }.toList()
                                val relations=JSONObject()
                                for(kind in listOf("video","audio")) {
                                    val expected=java.net.URI(media.getJSONObject("niconico").getString(kind))
                                    val nearest=refs.maxByOrNull { (if(it.rawPath==expected.rawPath)8 else 0)+(if(it.rawQuery==expected.rawQuery)4 else 0)+(if(it.host==expected.host)2 else 0)+(if(it.scheme==expected.scheme)1 else 0) }
                                    if(nearest!=null)relations.put(kind,JSONObject().put("exact",nearest==expected).put("normalized",nearest.normalize()==expected.normalize())
                                        .put("scheme",nearest.scheme==expected.scheme).put("host",nearest.host==expected.host).put("port",nearest.port==expected.port)
                                        .put("raw_path",nearest.rawPath==expected.rawPath).put("decoded_path",nearest.path==expected.path)
                                        .put("raw_query",nearest.rawQuery==expected.rawQuery).put("decoded_query",nearest.query==expected.query)
                                        .put("declared_default_port",nearest.port==443).put("observed_default_port",expected.port==443)
                                        .put("dot_segments",nearest.rawPath.orEmpty().split('/').any { it in setOf(".","..") }))
                                }
                                item.put("declared_relations",relations)
                            }
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
                                .put("display_width",it.displayWidth).put("pixel_aspect",it.pixelAspect).put("duration",it.duration)
                        }
                    }
                } catch(error:Exception) {
                    item.put("error_type",error.javaClass.simpleName)
                    if(error is MediaServerFailure)item.put("http_status",error.httpStatus).put("transport_error",error.transportError)
                    Regex("(?:HTTP|response code:?)\\s*([0-9]{3})",RegexOption.IGNORE_CASE).find(error.message.orEmpty())?.groupValues?.get(1)?.toIntOrNull()?.let { item.put("http_status",it) }
                    throw error
                }
            },{true})
            stage="selection"
            if(niconico) {
                stage="niconico_selection"
                val bound=WebVideoNiconicoCapture.candidate(page,media) ?: error("Niconico candidate unavailable")
                val data=media.getJSONObject("niconico")
                val inspected=capture.inspectCurrentHls(page,bound,java.net.URI(data.getString("root")) to data.getString("master_playlist")).getJSONArray("formats")
                result.put("selection_input",JSONArray((0 until inspected.length()).map { i ->
                    val f=inspected.getJSONObject(i)
                    fun codec(name: String)=f.optString(name).takeIf { it.matches(Regex("[A-Za-z0-9._-]{1,64}")) } ?: "other"
                    JSONObject().put("width",f.optInt("width")).put("height",f.optInt("height")).put("video_codec",codec("vcodec")).put("audio_codec",codec("acodec"))
                        .put("video_url_matches",f.optString("url")==data.getString("video")).put("audio_url_matches",f.optString("url")==data.getString("audio"))
                }))
                stage="selection"
            }
            if(iqiyi) {
                val data=media.getJSONObject("iqiyi");val plan=WebBrowserIqiyi.resourcePlan(media,media.getString("frame"))
                result.put("selection_input",JSONObject().put("sdk_plan",plan!=null).put("sdk_duration_ms",data.optDouble("dispatch_duration_ms"))
                    .put("dom_duration",media.optDouble("duration")).put("sdk_files",data.optJSONArray("dispatchers")?.length() ?: 0)
                    .put("normalized_duration",plan?.optString("playlist")?.lineSequence()?.filter { it.startsWith("#EXTINF:") }?.sumOf { it.substringAfter(':').substringBefore(',').toDouble() }))
            }
            if(tencent) {
                val data=media.getJSONObject("tencent")
                result.put("selection_input",JSONObject().put("candidate_bound",WebVideoTencentCapture.candidate(page,media)!=null)
                    .put("observed_count",WebBrowserNetworkMedia.candidates(media,true).length())
                    .put("dom_duration",media.optDouble("duration")).put("metadata_duration",data.optDouble("duration"))
                    .put("content_duration",data.optDouble("content_duration"))
                    .put("playlist_duration",data.optString("playlist").lineSequence().filter { it.startsWith("#EXTINF:") }.sumOf { it.substringAfter(':').substringBefore(',').toDouble() }))
            }
            val info=(if(bilibili) WebVideoBilibiliCapture.formats(page,media) else if(douyin) WebVideoDouyinCapture.resolve(page,media,capture) else if(weibo) WebVideoWeiboCapture.resolve(page,media,capture) else if(tencent) WebVideoTencentCapture.resolve(page,media,capture) else if(mango) WebVideoMangoCapture.resolve(page,media,capture) else if(dailymotion)WebVideoDailymotionCapture.resolve(page,media,capture) else if(ted)WebVideoTedCapture.resolve(page,media,capture) else if(redbull)WebVideoRedBullCapture.resolve(page,media,capture) else if(instagram)WebVideoInstagramCapture.resolve(page,media,capture) else if(tiktok)WebVideoTikTokCapture.resolve(page,media,capture) else if(naver)WebVideoNaverCapture.resolve(page,media,capture) else if(reddit)WebVideoRedditCapture.resolve(page,media,capture) else if(streamable)WebVideoStreamableCapture.resolve(page,media,capture) else if(odysee)WebVideoOdyseeCapture.resolve(page,media,capture) else if(archive)WebVideoArchiveCapture.resolve(page,media,capture) else if(twitch)WebVideoTwitchCapture.resolve(page,media,capture) else if(niconico)WebVideoNiconicoCapture.resolve(page,media,capture) else if(youku) WebVideoYoukuCapture.resolve(page,media,capture) else if(iqiyi) WebVideoIqiyiCapture.resolve(page,media,capture) else capture.resolveCurrent(page,media)) ?: error("Current stream not bound")
            val selected=WebVideoFormats.select(page,info){true}
            if (bilibili && selected.video.videoCodec.startsWith("av01")) {
                val profile = WebVideoCapabilities.av1SdrProfile(selected.video.videoCodec)
                result.put("av1_sdr_profile", profile)
                check(profile != null)
            }
            result.put("site",page.site).put("width",selected.video.width).put("height",selected.video.height)
                .put("video_codec",selected.video.videoCodec).put("audio_codec",selected.audio?.audioCodec ?: selected.video.audioCodec)
                .put("transport",selected.video.transport).put("current_size",selected.video.width==media.optInt("width") && selected.video.height==media.optInt("height"))
            check(result.getBoolean("current_size") && (bilibili || douyin || weibo || tencent || twitch || naver || reddit || streamable || archive || odysee || tiktok || instagram || selected.video.transport=="hls"))
            stage="lease"
            LocalStreamServer().use { server -> WebVideoStreams { server }.use { streams ->
                val local=streams.prepare(selected)
                val audio=streams.audio(page.url).firstOrNull()?.location
                stage="probe"
                val probe=run(listOf("ffprobe","-v","error","-show_entries","stream=codec_type,codec_name,width,height,pix_fmt,color_space,color_transfer,color_primaries,sample_aspect_ratio,sample_rate,channels:format=duration,start_time","-of","json",local))
                check(probe.code==0)
                val tracks=JSONObject(probe.bytes.toString(Charsets.UTF_8)).getJSONArray("streams")
                val list=(0 until tracks.length()).map{tracks.getJSONObject(it)}
                val video=list.first{it.optString("codec_type")=="video"}
                val sound=list.firstOrNull{it.optString("codec_type")=="audio"}
                result.put("streams",tracks)
                result.put("format_timing",JSONObject(probe.bytes.toString(Charsets.UTF_8)).optJSONObject("format"))
                val aspect=Regex("([1-9][0-9]{0,9}):([1-9][0-9]{0,9})").matchEntire(video.optString("sample_aspect_ratio"))
                val numerator=aspect?.groupValues?.get(1)?.toLong() ?: 1L;val denominator=aspect?.groupValues?.get(2)?.toLong() ?: 1L
                check(numerator<=0xffffffffL && denominator<=0xffffffffL && numerator<=denominator*16 && denominator<=numerator*16)
                val displayWidth=video.getInt("width").toLong()*numerator/denominator
                result.put("decoded_display_width",displayWidth)
                check((if(archive)displayWidth==media.optInt("width").toLong() else video.getInt("width")==media.optInt("width")) && video.getInt("height")==media.optInt("height"))
                val redditGif=reddit && media.getJSONObject("reddit").optString("binding")=="rendered_gif" && media.getJSONObject("reddit").opt("declared_gif")==true
                val explicitSilent=selected.silent && (instagram && media.getJSONObject("instagram").get("has_audio")==false || redditGif)
                if(reddit)result.put("reddit_gif_file",redditGif)
                result.put("explicit_silent",explicitSilent).put("audio_absent_verified",explicitSilent && sound==null && audio==null)
                check(sound!=null || audio!=null || result.getBoolean("audio_absent_verified"))
                val duration=media.getDouble("duration")
                // Resource-only iQIYI preflight covers the beginning and tail, separately
                // from the future real-button resume-position acceptance.
                val start=if(instagram || tiktok)media.getJSONObject(if(instagram)"instagram" else "tiktok").getDouble("start_seconds").coerceIn(0.0,maxOf(0.0,duration-4.0)) else if(iqiyi && media.optLong("iqiyi_request")==0L)0.0 else media.optDouble("time").coerceIn(0.0,maxOf(0.0,duration-4.0))
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
                fun decode(at: Double, label: String = if(at==start) "decode" else "seek"): Boolean {
                    // CLI input seeking can discard up to the *next* HLS keyframe.
                    // Keep a bounded preroll, then accurately trim the same requested
                    // target; a three-second sample must not end inside that GOP gap.
                    val preroll = if (selected.video.transport == "hls") minOf(20.0,at) else 0.0
                    val command=mutableListOf("ffmpeg","-v","error","-progress","pipe:1","-nostats")
                    // Seeking to exactly zero can skip the initial HLS GOP. A real
                    // initial playback opens the beginning without an input seek.
                    if(at-preroll>0)command+=listOf("-ss",(at-preroll).toString())
                    command+=listOf("-i",local)
                    if(audio!=null) {
                        if(at-preroll>0)command+=listOf("-ss",(at-preroll).toString())
                        command+=listOf("-i",audio)
                    }
                    if(preroll>0)command+=listOf("-ss",preroll.toString())
                    command+=listOf("-t","3","-map","0:v:0")
                    if(!explicitSilent)command+=listOf("-map",if(audio==null)"0:a:0" else "1:a:0")
                    command+=listOf("-f","null","-")
                    val output=run(command)
                    val frames=Regex("(?m)^frame=([0-9]+)").findAll(output.bytes.toString(Charsets.UTF_8)).map{it.groupValues[1].toInt()}.maxOrNull() ?: 0
                    result.put(if(label=="decode") "frames" else "${label}_frames",frames)
                    result.put("${label}_exit",output.code).put("${label}_diagnostics",output.diagnostics)
                    return output.code==0 && frames>=8
                }
                stage="joint_decode";result.put("decoded",decode(start)).put("start_seconds",start)
                stage="audio_decode"
                val soundAt=if(iqiyi && duration>120)duration/2 else minOf(maxOf(start,20.0),maxOf(0.0,duration-4.0))
                val audioPreroll = if (selected.video.transport == "hls") minOf(20.0,soundAt) else 0.0
                val pcm=if(explicitSilent)null else run(listOf("ffmpeg","-v","error","-ss",(soundAt-audioPreroll).toString(),"-i",audio ?: local,"-ss",audioPreroll.toString(),"-t","3","-map","0:a:0","-vn","-ac","2","-ar","48000","-f","s16le","pipe:1"),1024*1024)
                result.put("audio_samples_48k_stereo",(pcm?.bytes?.size ?: 0)/4).put("audio_nonzero",pcm?.bytes?.any{it!=0.toByte()} ?: false)
                    .put("audio_seconds",soundAt)
                val usualSeekAt=if(instagram)duration/2 else if(niconico && duration>120)duration/2 else if(douyin && duration>120)duration/2 else if(iqiyi && duration>120)duration-4 else minOf(start+20.0,maxOf(0.0,duration-4.0))
                val seekAt=if(kotlin.math.abs(usualSeekAt-start)<.1) { if(start>.1)0.0 else duration/2 } else usualSeekAt
                stage="seek_decode";result.put("seeked",decode(seekAt,"seek")).put("seek_seconds",seekAt).put("seek_distance_seconds",kotlin.math.abs(seekAt-start))
                // Check distant tail resources, then actually seek back to the middle
                // before returning. iQIYI's normal skip-credits action can navigate to
                // the next episode when a paused HTML video is restored into its outro.
                val returnAt=if(iqiyi && duration>120)duration/2 else seekAt
                val returnSeeked=if(returnAt!=seekAt) { stage="return_decode";decode(returnAt,"return") } else result.getBoolean("seeked")
                result.put("return_seeked",returnSeeked).put("return_seconds",returnAt)
                streams.release(local);result.put("lease_closed",!server.hasSource(local))
                result.put("passed",result.getBoolean("decoded") && result.getBoolean("seeked") && returnSeeked && (if(explicitSilent)result.getBoolean("audio_absent_verified") else pcm!=null && pcm.code==0 && pcm.bytes.size>=48000*4*2 && result.getBoolean("audio_nonzero")) && result.getBoolean("lease_closed"))
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
