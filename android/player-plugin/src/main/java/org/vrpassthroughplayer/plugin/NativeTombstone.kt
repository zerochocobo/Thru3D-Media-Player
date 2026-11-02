package org.vrpassthroughplayer.plugin

/**
 * Reads the protobuf tombstone Android 12+ hands back for this app's own native crash
 * (ApplicationExitInfo.getTraceInputStream) into the familiar text: signal, abort message,
 * the crashing thread's backtrace, other threads' top frames and the process's last log lines.
 * Field numbers follow system/core/debuggerd/proto/tombstone.proto.
 */
internal object NativeTombstone {
    private class Field(val number: Int, val type: Int, val value: Long, val bytes: ByteArray?)

    private fun fields(data: ByteArray): List<Field> {
        val out = ArrayList<Field>()
        var pos = 0
        fun varint(): Long {
            var result = 0L; var shift = 0
            while (true) {
                require(pos < data.size && shift < 64)
                val byte = data[pos++].toInt()
                result = result or ((byte and 0x7f).toLong() shl shift)
                if (byte and 0x80 == 0) return result
                shift += 7
            }
        }
        fun fixed(size: Int): Long {
            require(pos + size <= data.size)
            var result = 0L
            for (index in 0 until size) result = result or ((data[pos + index].toLong() and 0xff) shl (8 * index))
            pos += size
            return result
        }
        while (pos < data.size) {
            val key = varint()
            val number = (key ushr 3).toInt(); val type = (key and 7).toInt()
            when (type) {
                0 -> out.add(Field(number, type, varint(), null))
                1 -> out.add(Field(number, type, fixed(8), null))
                2 -> {
                    val length = varint().toInt()
                    require(length >= 0 && pos + length <= data.size)
                    out.add(Field(number, type, 0, data.copyOfRange(pos, pos + length))); pos += length
                }
                5 -> out.add(Field(number, type, fixed(4), null))
                else -> error("Unsupported wire type $type")
            }
        }
        return out
    }

    private fun List<Field>.text(number: Int) = lastOrNull { it.number == number && it.bytes != null }?.bytes?.toString(Charsets.UTF_8).orEmpty()
    private fun List<Field>.long(number: Int) = lastOrNull { it.number == number && it.bytes == null }?.value ?: 0L
    private fun List<Field>.messages(number: Int) = filter { it.number == number && it.bytes != null }.map { fields(it.bytes!!) }

    private fun frame(index: Int, frame: List<Field>): String = buildString {
        append("  #").append(index.toString().padStart(2, '0')).append(" pc ").append("%016x".format(frame.long(1)))
        append(' ').append(frame.text(6).ifEmpty { "<unknown>" })
        val function = frame.text(4)
        if (function.isNotEmpty()) append(" (").append(function).append('+').append(frame.long(5)).append(')')
        val build = frame.text(8)
        if (build.isNotEmpty()) append(" BuildId: ").append(build)
    }

    /** Text form of [data]; throws if it is not a tombstone. */
    fun describe(data: ByteArray, logLines: Int = 200): String = buildString {
        val root = fields(data)
        val tid = root.long(6).toInt()
        val signal = root.messages(10).firstOrNull()
        require(signal != null || root.any { it.number == 16 }) { "Not a tombstone" }
        append("pid: ").append(root.long(5)).append(", tid: ").append(tid).append('\n')
        if (signal != null) {
            append("signal ").append(signal.long(1)).append(" (").append(signal.text(2)).append("), code ").append(signal.long(3))
                .append(" (").append(signal.text(4)).append(')')
            if (signal.long(8) != 0L) append(", fault addr 0x").append(java.lang.Long.toHexString(signal.long(9)))
            append('\n')
        }
        root.text(14).takeIf { it.isNotEmpty() }?.let { append("Abort message: ").append(it).append('\n') }
        root.messages(15).map { it.text(1) }.filter { it.isNotEmpty() }.forEach { append("Cause: ").append(it).append('\n') }
        // map<uint32, Thread>: each entry is a message with key=1 and value=2.
        val threads = root.messages(16).mapNotNull { entry -> entry.messages(2).firstOrNull() }
        val crashing = threads.firstOrNull { it.long(1).toInt() == tid }
        if (crashing != null) {
            append("\nCrashing thread ").append(tid).append(" \"").append(crashing.text(2)).append("\" backtrace:\n")
            crashing.messages(4).take(64).forEachIndexed { index, frame -> append(frame(index, frame)).append('\n') }
        }
        val others = threads.filter { it !== crashing }
        if (others.isNotEmpty()) {
            append("\nOther threads (top frames):\n")
            for (thread in others.take(80)) {
                append(thread.long(1)).append(" \"").append(thread.text(2)).append("\"\n")
                thread.messages(4).take(3).forEachIndexed { index, frame -> append(frame(index, frame)).append('\n') }
            }
        }
        val logs = root.messages(18).flatMap { buffer -> buffer.messages(2) }
        if (logs.isNotEmpty()) {
            append("\nLast log lines of the crashed process:\n")
            val levels = "??VDIWEF"
            for (line in logs.takeLast(logLines)) {
                append(line.text(1)).append(' ').append(line.long(2)).append(' ').append(line.long(3)).append(' ')
                    .append(levels.getOrElse(line.long(4).toInt()) { '?' }).append(' ').append(line.text(5)).append(": ")
                    .append(line.text(6).trimEnd()).append('\n')
            }
        }
    }
}
