package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.text.Normalizer
import java.util.Locale

/** Pure subtitle/selection rules. Text and cue identities stay in memory. */
internal object NarrationPolicy {
    // Normal playback feature in both Debug and Release.
    const val FEATURE_ENABLED = BuildConfig.NARRATION_ENABLED
    // Fixed upstream README lists 19 languages. These do not add voice-origin presets.
    private val previews = linkedMapOf(
        "zh" to "你好，很高兴为您提供字幕朗读服务。",
        "en" to "Hello, I'm happy to read subtitles for you.",
        "ja" to "こんにちは。喜んで字幕を読み上げます。",
        "de" to "Hallo, ich lese Ihnen gerne die Untertitel vor.",
        "es" to "Hola, será un placer leer los subtítulos para usted.",
        "fr" to "Bonjour, je vous lirai les sous-titres avec plaisir.",
        "it" to "Salve, sarà un piacere leggere i sottotitoli per lei.",
        "hu" to "Üdvözlöm, örömmel olvasom fel Önnek a feliratokat.",
        "ko" to "안녕하세요. 기쁜 마음으로 자막을 읽어 드리겠습니다.",
        "ru" to "Здравствуйте! С удовольствием прочитаю для вас субтитры.",
        "fa" to "سلام، با کمال میل زیرنویس‌ها را برای شما می‌خوانم.",
        "ar" to "مرحبًا، يسعدني أن أقرأ لك نصوص الترجمة.",
        "pl" to "Dzień dobry, z przyjemnością przeczytam dla Państwa napisy.",
        "pt" to "Olá, será um prazer ler as legendas para você.",
        "cs" to "Dobrý den, s potěšením vám přečtu titulky.",
        "da" to "Hej, jeg vil med glæde læse underteksterne op for dig.",
        "sv" to "Hej, jag läser gärna upp undertexterna för dig.",
        "el" to "Γεια σας, με χαρά θα σας διαβάσω τους υπότιτλους.",
        "tr" to "Merhaba, altyazıları sizin için memnuniyetle seslendireceğim.")
    val languages: Set<String> = previews.keys
    fun previewText(language: String): String = requireNotNull(previews[language]) { "unsupported_language" }
    val voices = mapOf("zh" to listOf("Xiaoyu", "Yuewen", "Lingyu", "Zhiming", "Junhao"), "en" to listOf("Ava", "Bella", "Adam"), "ja" to listOf("Mei", "Saki", "Mortis", "Umiri"))
    data class Config(val enabled: Boolean = false, val source: Int = -1, val language: String = "auto",
                      val zhVoice: String = "Xiaoyu", val enVoice: String = "Ava", val duck: Double = .75,
                      val volume: Double = 1.0, val offset: Double = 0.0, val retry: Int = 0,
                      val sourceDelay: Double? = null, val preview: Int = 0, val timing: String = "interrupt",
                      val jaVoice: String = "Mei", val line: Int = 0, val voiceOverride: String = "") {
        fun voice(lang: String) = if(voiceOverride.isNotEmpty())voiceOverride else when(lang) { "zh" -> zhVoice; "ja" -> jaVoice; else -> enVoice }
        val deadlineSlack get() = when(timing) {"interrupt"->0.0;"continuous"->3.0;else->.4}
        companion object {
            fun parse(json: String): Config {
                val j = JSONObject(json)
                val c = Config(j.optBoolean("enabled"), j.optInt("source", -1), j.optString("language", "auto"),
                    j.optString("zh_voice", "Xiaoyu"), j.optString("en_voice", "Ava"), j.optDouble("duck", .75),
                    j.optDouble("volume", 1.0), j.optDouble("offset", 0.0), j.optInt("retry"),
                    if(j.isNull("source_delay"))null else j.getDouble("source_delay"),j.optInt("preview"),j.optString("timing","interrupt"),j.optString("ja_voice","Mei"),j.optInt("line",0),j.optString("voice_override",""))
                require(c.voiceOverride.isEmpty() || c.voiceOverride in voices.values.flatten() || PersonalVoiceStore.isVoice(c.voiceOverride))
                require(c.source >= -1 && (c.language == "auto" || c.language in languages) && c.zhVoice in voices.getValue("zh") && c.enVoice in voices.getValue("en") && c.jaVoice in voices.getValue("ja") && c.line in 0..2)
                require(c.duck.isFinite() && c.duck in 0.0..1.0 && c.volume.isFinite() && c.volume in 0.0..1.0 &&
                    c.offset.isFinite() && c.offset in -2.0..2.0)
                require(c.sourceDelay == null || c.sourceDelay.isFinite() && c.sourceDelay in -10.0..10.0)
                require(c.timing in setOf("interrupt","continuous","strict"))
                return c
            }
        }
    }
    data class Cue(val start: Double, val end: Double, val text: String, val windowStart: Double = start, val windowEnd: Double = end) {
        val key get() = "$start:$end:$text"
    }
    /** Playback text is authoritative for a cue already being prepared. A later
     * prefetch result must not make a second utterance for that displayed window. */
    fun mergeDisplayed(prefetched: List<Cue>, displayed: List<Cue>): Pair<List<Cue>,List<String>> {
        val replaced=prefetched.filter {cue -> displayed.none {it.key==cue.key} && displayed.any {
            cue.windowStart<it.windowEnd && cue.windowEnd>it.windowStart
        }}
        return (prefetched-replaced.toSet()+displayed).distinctBy {it.key}.sortedBy {it.start} to replaced.map {it.key}
    }
    data class PlaybackClock(val position: Double,val observedNs: Long,val kind: String)
    fun playbackClock(observation: JSONObject): PlaybackClock {
        val video=observation.optString("position_seconds").toDoubleOrNull()?.takeIf {it.isFinite()&&it>=0} ?: 0.0
        val videoClock=PlaybackClock(video,observation.optLong("observed_monotonic_ns"),"video")
        // time-pos changes once per video frame. Audio PTS includes driver delay
        // and gives the presentation clock between frames. The player's audio
        // delay follows frames held for masks: keep that delay in presentation,
        // using it only to reject an old audio timestamp after a seek.
        // Audio-track sync must not shift subtitle narration away from the picture.
        val userDelay=observation.optDouble("user_audio_delay_seconds",0.0)
        val audio=observation.optDouble("audio_pts_us",Double.NaN)/1e6+userDelay
        val pipelineDelay=observation.optDouble("audio_delay_seconds",0.0)-userDelay
        val audioNs=observation.optLong("audio_observed_monotonic_ns")
        val stopped=observation.optString("paused")=="yes"||observation.optString("paused_for_cache")=="yes"
        val noTrack=observation.optString("audio_track_id") in setOf("","no","0")
        return if(!stopped&&!noTrack&&observation.optBoolean("audio_clock_available")&&audioNs>0&&audio.isFinite()&&pipelineDelay.isFinite()&&kotlin.math.abs(audio+pipelineDelay-video)<=.5)
            PlaybackClock(audio,audioNs,"audio") else videoClock
    }
    fun language(tag: String): String {
        val code=tag.trim().replace('_', '-').lowercase(Locale.ROOT).substringBefore('-')
        if(code in languages)return code
        return when(code) {
            "zho", "chi", "cmn", "chs", "cht" -> "zh"; "eng" -> "en"; "jpn" -> "ja"
            "deu", "ger" -> "de"; "spa" -> "es"; "fra", "fre" -> "fr"; "ita" -> "it"; "hun" -> "hu"; "kor" -> "ko"
            "rus" -> "ru"; "fas", "per" -> "fa"; "ara" -> "ar"; "pol" -> "pl"; "por" -> "pt"; "ces", "cze" -> "cs"
            "dan" -> "da"; "swe" -> "sv"; "ell", "gre" -> "el"; "tur" -> "tr"
            else -> ""
        }
    }
    fun clean(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFKC)
        .replace(Regex("\\{[^}]*\\}"), "").replace("\\N", "\n").replace("\\n", "\n").replace("\\h", " ")
        .replace(Regex("<br\\s*/?>", RegexOption.IGNORE_CASE), "\n")
        .replace(Regex("<[^>]*>"), "").replace("&nbsp;", " ").replace("&amp;", "&")
        .replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'")
        .replace(Regex("[\\p{Cc}&&[^\\n\\t]]"), "").trim().take(2048)

    fun cues(array: JSONArray, lang: String, line: Int = 0): List<Cue> {
        require(line in 0..8)
        val original = (0 until array.length()).mapNotNull { i ->
            val j = array.getJSONObject(i); val start = j.optDouble("start"); val end = j.optDouble("end"); val text = clean(j.optString("text"))
            if (start.isFinite() && end.isFinite() && start >= 0 && end > start && text.isNotBlank()) Cue(start, end, text) else null
        }.distinct().sortedBy { it.start }
        val merged = mutableListOf<Cue>()
        for (cue in original) {
            val previous = merged.lastOrNull()
            if (previous != null && cue.start < previous.end && (cue.text == previous.text || cue.start == previous.start)) {
                val text = if (cue.text.contains(previous.text)) cue.text else if (previous.text.contains(cue.text)) previous.text else previous.text + "\n" + cue.text
                merged[merged.lastIndex] = Cue(previous.start, maxOf(previous.end, cue.end), text)
            } else merged += cue
        }
        return merged.flatMap { cue ->
            // Select authored lines after merging simultaneous bilingual events, before
            // speech chunking. Layout wrapping is deliberately not a subtitle line.
            val selected = if(line == 0) cue.text else cue.text.lines().filter {it.isNotBlank()}.getOrNull(line-1).orEmpty()
            val limit = if (lang in setOf("zh", "ja")) 65 else 180
            val parts = mutableListOf<String>(); var rest = selected
            while (rest.length > limit) {
                val cut = (rest.take(limit).indexOfLast { it in "。！？.!?;；，, " } + 1).takeIf { it >= limit / 3 } ?: limit
                parts += rest.take(cut).trim(); rest = rest.drop(cut).trim()
            }
            if (rest.isNotBlank()) parts += rest
            var used = 0
            val total = parts.sumOf { it.length }.coerceAtLeast(1)
            parts.map { part ->
                val start = cue.start + (cue.end-cue.start)*used/total
                used += part.length
                Cue(start, cue.start+(cue.end-cue.start)*used/total, normalize(part, lang), cue.start, cue.end)
            }
        }
    }
    private val small = listOf("zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen")
    private val tens = listOf("", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety")
    private fun english(n: Long): String = when {
        n < 20 -> small[n.toInt()]
        n < 100 -> tens[(n / 10).toInt()] + if (n % 10 == 0L) "" else " " + english(n % 10)
        n < 1000 -> english(n/100) + " hundred" + if (n%100==0L) "" else " " + english(n%100)
        else -> {
            val unit = if (n >= 1_000_000_000) 1_000_000_000L else if (n >= 1_000_000) 1_000_000L else 1000L
            english(n/unit) + when (unit) {1000L -> " thousand"; 1_000_000L -> " million"; else -> " billion"} + if (n%unit==0L) "" else " " + english(n%unit)
        }
    }
    private fun chinese(n: Long): String {
        if (n == 0L) return "零"
        if (n >= 100_000_000) return chinese(n/100_000_000) + "亿" + if (n%100_000_000==0L) "" else (if(n%100_000_000<10_000_000) "零" else "") + chinese(n%100_000_000)
        if (n >= 10000) return chinese(n/10000) + "万" + if (n%10000==0L) "" else (if(n%10000<1000) "零" else "") + chinese(n%10000)
        val digits="零一二三四五六七八九"; val units=listOf("", "十", "百", "千");val out=StringBuilder(); var zero=false
        val s=n.toString()
        for ((i,c) in s.withIndex()) {val d=c-'0';val place=s.length-i-1
            if(d==0) {zero=out.isNotEmpty();continue}
            if(zero)out.append('零');zero=false
            if(!(d==1&&place==1&&out.isEmpty()))out.append(digits[d]);out.append(units[place])
        }
        return out.toString()
    }
    fun normalize(text: String, lang: String): String {
        // Only these two frontends expand numbers. Preserve every other language
        // for the multilingual model rather than injecting English number words.
        if(lang !in setOf("zh","en")) return text
        val digits="零一二三四五六七八九"
        var value=text
        // Android ICU's \d includes non-ASCII digits, which cannot index this ASCII digit table.
        if(lang=="zh")value=value.replace(Regex("[0-9]{4}(?=年)")) { m -> m.value.map { digits[it-'0'] }.joinToString("") }
        return value.replace(Regex("(?<![A-Za-z])[-+]?[0-9]+(?:\\.[0-9]+)?%?")) { m ->
            val raw=m.value;val body=raw.trimStart('-', '+').removeSuffix("%");val parts=body.split('.')
            val n=parts[0].toLongOrNull()
            val integer=if(n!=null&&n<=999_999_999&&!(parts[0].length>1&&parts[0].startsWith('0'))) {
                if(lang=="zh")chinese(n) else english(n)
            } else parts[0].map { if(lang=="zh")digits[it-'0'].toString() else small[it-'0'] }.joinToString(if(lang=="zh")"" else " ")
            val decimal=if(parts.size==1)"" else (if(lang=="zh")"点" else " point ")+parts[1].map {if(lang=="zh")digits[it-'0'].toString() else small[it-'0']}.joinToString(if(lang=="zh")"" else " ")
            (if(raw.startsWith('-'))if(lang=="zh")"负" else "minus " else "") +
                (if(raw.endsWith('%')&&lang=="zh")"百分之" else "") + integer + decimal + if(raw.endsWith('%')&&lang!="zh")" percent" else ""
        }
    }
    // A single automatic speed rule; obsolete saved manual rates are ignored.
    // The final output tempo (including video speed) shares the same cap.
    const val MAX_ADAPTIVE_RATE = 1.8
    const val MAX_BORROW_SECONDS = 2.0
    const val TARGET_BORROW_SECONDS = .5
    fun interruptBoundary(cue: Cue, cues: List<Cue>): Double =
        cues.filter {it.windowStart>cue.windowStart+.001}.minOfOrNull {it.windowStart} ?: Double.POSITIVE_INFINITY
    fun speechDeadline(cue: Cue, cues: List<Cue>) = interruptBoundary(cue,cues)+MAX_BORROW_SECONDS
    fun afterSeek(cue: Cue, floor: Double, offset: Double) = !floor.isFinite() || cue.end+offset>floor
    data class SpeechBudget(val seconds: Double,val deadline: Double)
    /** Earliest-deadline demand over the current and following sentences. Silence
     * is usable time; aim to recover within .5s, with a separate 2s hard limit. */
    fun plannedTempo(budgets: List<SpeechBudget>, position: Double, speed: Double, queuedSeconds: Double, preferredTempo: Double): Double {
        var cumulative=0.0;var tempo=preferredTempo
        for(budget in budgets) {
            cumulative+=budget.seconds.coerceAtLeast(0.0)
            tempo=maxOf(tempo,fittedTempo(cumulative,(budget.deadline-position)/speed-queuedSeconds-.04,preferredTempo))
        }
        return tempo.coerceIn(.25,MAX_ADAPTIVE_RATE)
    }
    fun streamingReady(samples: Int, rate: Double, remaining: Double, interrupting: Boolean): Boolean =
        samples>=38400 || interrupting && remaining.isFinite() && remaining>0 && samples>=15360 && samples/96000.0/rate>=remaining+.04
    // Native generation is bounded at 250 * 80ms = 20s. A preview at the
    // slowest selectable rate (.8) needs 25s plus presentation margin.
    const val PREVIEW_WINDOW_SECONDS = 30.0
    private fun availableSpeechTime(windowSeconds: Double, latenessSeconds: Double) =
        (windowSeconds-latenessSeconds.coerceAtLeast(0.0)-.25).coerceAtLeast(.1)
    fun playbackRate(audioSeconds: Double, windowSeconds: Double, latenessSeconds: Double, preferredRate: Double): Double =
        maxOf(preferredRate,audioSeconds/availableSpeechTime(windowSeconds,latenessSeconds)).coerceAtMost(MAX_ADAPTIVE_RATE)
    /** Actual output tempo, including video speed, never exceeds the approved 1.8x cap.
     * Infinite available time means there is no known following subtitle. */
    fun fittedTempo(audioSeconds: Double, availableWallSeconds: Double, preferredTempo: Double): Double =
        maxOf(preferredTempo,if(availableWallSeconds.isFinite()&&audioSeconds>0)
            audioSeconds/availableWallSeconds.coerceAtLeast(.05) else preferredTempo).coerceIn(.25,MAX_ADAPTIVE_RATE)
    fun canFinish(audioSeconds: Double, windowSeconds: Double, latenessSeconds: Double, preferredRate: Double, slack: Double): Boolean =
        audioSeconds>0&&audioSeconds/playbackRate(audioSeconds,windowSeconds,latenessSeconds,preferredRate)+.02<=windowSeconds+slack-latenessSeconds.coerceAtLeast(0.0)
    fun frameBudget(windowSeconds: Double): Int =
        (availableSpeechTime(windowSeconds,0.0)*MAX_ADAPTIVE_RATE/.08).toInt().coerceIn(8,250)
    // EOS is a property of the utterance, not of how long a subtitle is visible.
    // A two-second subtitle may need three seconds of natural speech. Generate
    // the full sentence first; the output tempo owns its presentation budget.
    fun generationFrameBudget(text: String, language: String, windowSeconds: Double, minimumFrames: Int = 64): Int {
        val units=if(language in setOf("zh","ja"))text.count {it.isLetterOrDigit()} else Regex("[\\p{L}\\p{N}]+").findAll(text).count()
        val naturalSeconds=.8+units*(if(language in setOf("zh","ja")).45 else .7)
        // The original INT8 Junhao preset needs 52 frames for a valid short
        // caption in the ARM regression. Leave EOS room beyond that boundary.
        return maxOf(frameBudget(windowSeconds),kotlin.math.ceil(naturalSeconds/.08).toInt()).coerceIn(minimumFrames.coerceIn(48,64),250)
    }
    fun speechText(text: String, language: String): String {
        val value=Normalizer.normalize(text,Normalizer.Form.NFKC)
            .replace(Regex("[()\\[\\]{}\"“”„«»「」『』《》〈〉【】]"),"")
            .replace('’','\'').replace('‘','\'').replace(Regex("\\s+")," ").trim().trim('\'')
        if(value.isEmpty()||value.last() in "。！？!?….؟"||(language=="el"&&value.last()==';'))return value
        val phrase=value.trimEnd(',','，',';', '；', ':', '：').trimEnd()
        return if(phrase.isEmpty())"" else phrase+if(language in setOf("zh","ja"))"。" else "."
    }
    fun duck(position: Double, windows: List<Cue>, amount: Double, ready: Boolean): Double {
        if (!ready) return 1.0
        var start = -1.0; var end = -1.0
        for (cue in windows.sortedBy { it.windowStart }) {
            if (cue.windowStart > end + .25) {
                if (position >= start && position < end) return 1.0-amount
                start=cue.windowStart;end=cue.windowEnd
            } else end=maxOf(end,cue.windowEnd)
        }
        return if(position>=start&&position<end)1.0-amount else 1.0
    }
}
