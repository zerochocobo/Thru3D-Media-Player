package org.vrpassthroughplayer.plugin

import java.io.File
import java.util.Locale

/** Stable source/range names; both lossless containers share one duplicate identity. */
internal object ClipExportName {
    data class Existing(val name: String, val uri: String)

    fun base(sourceName: String, startUs: Long, endUs: Long): String {
        require(startUs >= 0 && endUs > startUs) { "Invalid loop range" }
        var stem = sourceName.substringAfterLast('/').substringAfterLast('\\').substringBeforeLast('.')
            .replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_").trim(' ', '.')
        if (stem.isBlank()) stem = "video"
        if (Regex("(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$").matches(stem)) stem = "_$stem"
        while (stem.toByteArray(Charsets.UTF_8).size > 160)
            stem = stem.dropLast(Character.charCount(stem.codePointBefore(stem.length)))
        fun time(us: Long): String {
            val ms = us / 1000
            return String.format(Locale.ROOT, "%02d-%02d-%02d.%03d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return "${stem}_${time(startUs)}--${time(endUs)}"
    }

    fun existing(directory: File, base: String, indexed: (String) -> Existing?): Existing? {
        for (extension in listOf("mp4", "mkv")) {
            val name = "$base.$extension"
            indexed(name)?.let { return it }
            val file = File(directory, name)
            if (file.isFile && file.length() > 0) return Existing(name, file.toURI().toString())
        }
        return null
    }
}
