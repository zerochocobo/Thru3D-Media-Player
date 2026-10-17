package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.text.Normalizer
import java.util.Locale

/** Pure subtitle/selection rules. Text and cue identities stay in memory. */
internal object NarrationPolicy {
    // Withheld in Debug and Release; resuming requires explicit user authorization.
    const val FEATURE_ENABLED = false
    val voices = mapOf("zh" to listOf("Yuewen", "Junhao"), "en" to listOf("Ava", "Adam"))
    data class Config(val enabled: Boolean = false, val source: Int = -1, val language: String = "auto",
                      val zhVoice: String = "Yuewen", val enVoice: String = "Ava", val duck: Double = .75,
                      val volume: Double = 1.0, val rate: Double = 1.0, val offset: Double = 0.0, val retry: Int = 0,
                      val sourceDelay: Double? = null, val preview: Int = 0) {
        fun voice(lang: String) = if (lang == "zh") zhVoice else enVoice
        companion object {
            fun parse(json: String): Config {
                val j = JSONObject(json)
                val c = Config(j.optBoolean("enabled"), j.optInt("source", -1), j.optString("language", "auto"),
                    j.optString("zh_voice", "Yuewen"), j.optString("en_voice", "Ava"), j.optDouble("duck", .75),
                    j.optDouble("volume", 1.0), j.optDouble("rate", 1.0), j.optDouble("offset", 0.0), j.optInt("retry"),
                    if(j.isNull("source_delay"))null else j.getDouble("source_delay"),j.optInt("preview"))
                require(c.source >= -1 && c.language in setOf("auto", "zh", "en") && c.zhVoice in voices.getValue("zh") && c.enVoice in voices.getValue("en"))
                require(c.duck.isFinite() && c.duck in 0.0..1.0 && c.volume.isFinite() && c.volume in 0.0..1.0 &&
                    c.rate.isFinite() && c.rate in .8..1.3 && c.offset.isFinite() && c.offset in -2.0..2.0)
                require(c.sourceDelay == null || c.sourceDelay.isFinite() && c.sourceDelay in -10.0..10.0)
                return c
            }
        }
    }
    data class Cue(val start: Double, val end: Double, val text: String, val windowStart: Double = start, val windowEnd: Double = end) {
        val key get() = "$start:$end:$text"
    }
    data class PlaybackClock(val position: Double,val observedNs: Long,val kind: String)
    fun playbackClock(observation: JSONObject): PlaybackClock {
        val video=observation.optString("position_seconds").toDoubleOrNull()?.takeIf {it.isFinite()&&it>=0} ?: 0.0
        val videoClock=PlaybackClock(video,observation.optLong("observed_monotonic_ns"),"video")
        // time-pos changes once per video frame. Audio PTS includes driver delay
        // and gives the presentation clock between frames. The player's audio
        // delay follows frames held for masks: keep that delay in presentation,
        // using it only to reject an old audio timestamp after a seek.
        val audio=observation.optDouble("audio_pts_us",Double.NaN)/1e6
        val pipelineDelay=observation.optDouble("audio_delay_seconds",0.0)
        val audioNs=observation.optLong("audio_observed_monotonic_ns")
        val stopped=observation.optString("paused")=="yes"||observation.optString("paused_for_cache")=="yes"
        val noTrack=observation.optString("audio_track_id") in setOf("","no","0")
        return if(!stopped&&!noTrack&&observation.optBoolean("audio_clock_available")&&audioNs>0&&audio.isFinite()&&pipelineDelay.isFinite()&&kotlin.math.abs(audio+pipelineDelay-video)<=.5)
            PlaybackClock(audio,audioNs,"audio") else videoClock
    }
    fun language(tag: String): String = when (tag.replace('_', '-').lowercase(Locale.ROOT).substringBefore('-')) {
        "zh", "zho", "chi", "cmn", "chs", "cht" -> "zh"
        "en", "eng" -> "en"
        else -> ""
    }
    fun clean(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFKC)
        .replace(Regex("\\{[^}]*\\}"), "").replace("\\N", "\n").replace("\\n", "\n").replace("\\h", " ")
        .replace(Regex("<[^>]*>"), "").replace("&nbsp;", " ").replace("&amp;", "&")
        .replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'")
        .replace(Regex("[\\p{Cc}&&[^\\n\\t]]"), "").trim().take(2048)

    fun cues(array: JSONArray, lang: String): List<Cue> {
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
            val limit = if (lang == "zh") 65 else 180
            val parts = mutableListOf<String>(); var rest = cue.text
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
    // The user preference remains .8..1.3. A long sentence may need a little
    // more acceleration to finish before the next subtitle, with pitch intact.
    const val MAX_ADAPTIVE_RATE = 1.4
    private fun availableSpeechTime(windowSeconds: Double, latenessSeconds: Double) =
        (windowSeconds-latenessSeconds.coerceAtLeast(0.0)-.25).coerceAtLeast(.1)
    fun playbackRate(audioSeconds: Double, windowSeconds: Double, latenessSeconds: Double, preferredRate: Double): Double =
        maxOf(preferredRate,audioSeconds/availableSpeechTime(windowSeconds,latenessSeconds)).coerceAtMost(MAX_ADAPTIVE_RATE)
    fun frameBudget(windowSeconds: Double): Int =
        (availableSpeechTime(windowSeconds,0.0)*MAX_ADAPTIVE_RATE/.08).toInt().coerceIn(8,250)
    fun hasPreparationLead(start: Double,end: Double,position: Double,advancing: Boolean=true): Boolean =
        !advancing || start-position>=minOf(5.0,(end-start)*.75)
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
