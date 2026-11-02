package org.vrpassthroughplayer.plugin

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Keeps what a crash leaves behind, so a user only has to reopen the app and save the log: whether the
 * last session ended abnormally (its [CrashTrail] marker), the system's exit record and stack where
 * Android keeps one (API 30+, native tombstone on 31+), a Java exception, the last steps, and the crashed
 * process's own logcat, copied before newer lines push it out. A crash is also saved to Download once.
 * Everything stored is already redacted ([DiagnosticLogs.redact]).
 */
internal object CrashRecords {
    private const val TAG = "CrashRecords"
    private const val REPORT = "last_report.txt"
    private const val PENDING = "pending_save"
    private const val JAVA_CRASH = "java_crash.txt"
    private const val EXIT_SEEN = "exit_seen"
    private const val LOG_BYTES = 1536 * 1024
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "CrashRecords").apply { isDaemon = true } }
    @Volatile private var started = false

    fun directory(context: Context) = File(context.filesDir, "diagnostics/crash")

    /** As early as possible in the process: the crashed process's logcat is overwritten as this one logs. */
    @Synchronized fun start(context: Context) {
        if (started) return
        started = true
        val app = context.applicationContext
        val directory = directory(app).apply { mkdirs() }
        val pid = android.os.Process.myPid()
        val previous = runCatching { CrashTrail.open(File(directory, "trail.bin"), pid) }
            .onFailure { Log.w(TAG, "Step ring unavailable: ${it.javaClass.simpleName}") }.getOrNull()
        installHandler(directory, pid)
        CrashTrail.mark("app.start", "api=${Build.VERSION.SDK_INT}")
        worker.execute {
            runCatching { analyze(app, directory, previous) }
                .onFailure { Log.w(TAG, "Crash record failed: ${it.javaClass.simpleName}") }
        }
    }

    private fun installHandler(directory: File, pid: Int) {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            runCatching {
                CrashTrail.mark("java.crash", error.javaClass.simpleName)
                File(directory, JAVA_CRASH).writeText("pid=$pid\nthread=${thread.name}\ntime=${stamp(System.currentTimeMillis())}\n\n" +
                    error.stackTraceToString().take(64 * 1024))
            }
            if (previous != null) previous.uncaughtException(thread, error)
            else { android.os.Process.killProcess(pid); kotlin.system.exitProcess(10) }
        }
    }

    fun foreground(value: Boolean) = CrashTrail.foreground(value)
    fun cleanExit() { CrashTrail.mark("app.exit"); CrashTrail.cleanExit() }

    class Exit(val pid: Int, val process: String, val reason: Int, val status: Int, val importance: Int,
               val pssKb: Long, val rssKb: Long, val timestamp: Long, val description: String, val trace: () -> String?) {
        val name get() = REASONS.getOrElse(reason) { "REASON_$reason" }
        /** What the user saw as a crash: a fault, or the system ending it while in front. */
        fun crash(foreground: Boolean) = reason in setOf(4, 5, 6, 7, 9) || (foreground && reason in setOf(0, 2, 3, 12, 13))
        fun summary() = "$name status=$status at ${stamp(timestamp)} process=$process pid=$pid importance=$importance " +
            "pss=${pssKb / 1024}MB rss=${rssKb / 1024}MB" + (if (description.isEmpty()) "" else " \"$description\"")
    }
    private val REASONS = listOf("UNKNOWN", "EXIT_SELF", "SIGNALED", "LOW_MEMORY", "CRASH", "CRASH_NATIVE", "ANR",
        "INITIALIZATION_FAILURE", "PERMISSION_CHANGE", "EXCESSIVE_RESOURCE_USAGE", "USER_REQUESTED", "USER_STOPPED",
        "DEPENDENCY_DIED", "OTHER", "FREEZER", "PACKAGE_STATE_CHANGE", "PACKAGE_UPDATED")

    /** Exit records Android added since the last launch (none below API 30). */
    private fun exits(context: Context, directory: File): List<Exit> {
        if (Build.VERSION.SDK_INT < 30) return emptyList()
        val manager = context.getSystemService(ActivityManager::class.java) ?: return emptyList()
        val seenFile = File(directory, EXIT_SEEN)
        val seen = runCatching { seenFile.readText().trim().toLong() }.getOrDefault(0L)
        val list = manager.getHistoricalProcessExitReasons(context.packageName, 0, 8).filter { it.timestamp > seen }
        if (list.isNotEmpty()) seenFile.writeText(list.maxOf { it.timestamp }.toString())
        return list.map { info ->
            Exit(info.pid, info.processName.orEmpty(), info.reason, info.status, info.importance, info.pss, info.rss,
                info.timestamp, info.description.orEmpty()) { trace(info) }
        }
    }

    private fun trace(info: ApplicationExitInfo): String? {
        val bytes = runCatching { info.traceInputStream?.use { read(it, 8 * 1024 * 1024) } }.getOrNull() ?: return null
        return when (info.reason) {
            ApplicationExitInfo.REASON_CRASH_NATIVE -> runCatching { NativeTombstone.describe(bytes) }
                .getOrElse { "Tombstone present but unreadable (${bytes.size} bytes)" }
            ApplicationExitInfo.REASON_ANR -> String(bytes, Charsets.UTF_8).take(256 * 1024)
            else -> null
        }
    }

    private fun read(input: InputStream, limit: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        while (out.size() < limit) {
            val count = input.read(buffer, 0, minOf(buffer.size, limit - out.size()))
            if (count < 0) break
            out.write(buffer, 0, count)
        }
        return out.toByteArray()
    }

    private fun analyze(context: Context, directory: File, previous: CrashTrail.Session?) {
        val exits = exits(context, directory)
        val javaFile = File(directory, JAVA_CRASH)
        val java = if (previous == null) null else runCatching { javaFile.readText() }.getOrNull()?.takeIf { it.startsWith("pid=${previous.pid}\n") }
        javaFile.delete()
        if (previous == null || previous.clean) return
        val main = exits.firstOrNull { it.pid == previous.pid }
        val crashed = decide(java != null, main?.let { it.crash(previous.foreground) }, previous.foreground)
        if (!crashed) return
        CrashTrail.mark("crash.found", main?.name ?: if (java != null) "JAVA" else "UNCLEAN")
        // Copy the crashed process's lines first; this process is filling the same ring buffer.
        val processLog = runCatching { DiagnosticLogs.logcat(previous.pid, "-t", "30000") }.getOrDefault("")
        val crashBuffer = runCatching { DiagnosticLogs.logcat(null, "-b", "crash", "-t", "400") }.getOrDefault("")
        val report = DiagnosticLogs.redact(compose(previous, exits, main, java, processLog, crashBuffer))
        val file = File(directory, REPORT)
        val temporary = File(directory, "$REPORT.tmp")
        temporary.writeText(report)
        if (!temporary.renameTo(file)) { file.delete(); temporary.renameTo(file) }
        File(directory, PENDING).writeText(System.currentTimeMillis().toString())
    }

    /** A Java exception or a crash-like exit record decides; without a record, an unclean exit while in front. */
    fun decide(java: Boolean, exitSaysCrash: Boolean?, foreground: Boolean) = java || (exitSaysCrash ?: foreground)

    private fun compose(previous: CrashTrail.Session, exits: List<Exit>, main: Exit?, java: String?, processLog: String, crashBuffer: String) = buildString {
        append("== Last abnormal exit ==\n")
        append("Session started ").append(stamp(previous.startedMs)).append(", pid ").append(previous.pid)
            .append(", in front: ").append(if (previous.foreground) "yes" else "no").append("; recorded ").append(stamp(System.currentTimeMillis())).append('\n')
        append("Exit: ").append(main?.summary() ?: if (Build.VERSION.SDK_INT < 30) "no system record below Android 11" else "no system record").append('\n')
        exits.filter { it !== main }.forEach { append("Other exit: ").append(it.summary()).append('\n') }
        val stack = main?.trace?.invoke()
        append("System stack: ").append(when {
            stack != null -> "retained"
            java != null -> "Java exception below"
            crashBuffer.contains("pid: ${previous.pid},") && crashBuffer.contains("backtrace:") -> "native backtrace in the crash buffer below"
            Build.VERSION.SDK_INT < 30 -> "unavailable below Android 11; see the process log below"
            main?.reason == 5 && Build.VERSION.SDK_INT < 31 -> "native stacks need Android 12; see the process log below"
            else -> "not retained by the system; see the steps and process log below"
        }).append('\n')
        if (java != null) append("\n-- Java exception --\n").append(java).append('\n')
        if (stack != null) append(if (main?.reason == 6) "\n-- ANR trace --\n" else "\n-- Native crash --\n").append(stack).append('\n')
        append("\n-- Last steps (newest last) --\n")
        if (previous.lines.isEmpty()) append("(none)\n") else previous.lines.takeLast(160).forEach { append(it).append('\n') }
        append("\n-- Crash buffer --\n").append(crashBuffer.ifBlank { "(empty)\n" })
        append("\n-- Log of the crashed process --\n")
        val log = DiagnosticLogs.condense(processLog)
        append(if (log.isBlank()) "(no longer in the system log)\n" else if (log.length > LOG_BYTES) "…\n" + log.takeLast(LOG_BYTES) else log)
    }

    /** Once privacy is known: a pending crash report goes to Download unless nothing may be recorded. */
    fun privacyReady(context: Context, mode: String, saved: (String) -> Unit) {
        val app = context.applicationContext
        worker.execute {
            val directory = directory(app)
            val pending = File(directory, PENDING)
            if (!pending.exists()) return@execute
            pending.delete()
            if (mode == "none") return@execute
            runCatching {
                val report = File(directory, REPORT).readText()
                val name = "thru3d-crash-" + SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()) + ".txt"
                saved(DiagnosticLogs.save(app, DiagnosticLogs.crashFile(app, report), name))
            }.onFailure { Log.w(TAG, "Crash report not saved: ${it.javaClass.simpleName}") }
        }
    }

    /** The last crash report (kept until a newer crash) and this session's steps, for the saved log. */
    fun exportSection(context: Context): String = buildString {
        val report = File(directory(context), REPORT)
        if (report.isFile) append(runCatching { report.readText() }.getOrDefault("== Last abnormal exit ==\n(unreadable)\n"))
        else append("== Last abnormal exit ==\nNone recorded\n")
        append("\n== Steps this session (newest last) ==\n")
        CrashTrail.current().takeLast(120).forEach { append(it).append('\n') }
    }

    /** Clearing playback records also drops the stored report (its logs may describe that playback). */
    fun clear(context: Context) {
        val directory = directory(context)
        worker.execute { listOf(REPORT, "$REPORT.tmp", PENDING, JAVA_CRASH).forEach { File(directory, it).delete() } }
    }

    private fun stamp(ms: Long) = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(ms))
}
