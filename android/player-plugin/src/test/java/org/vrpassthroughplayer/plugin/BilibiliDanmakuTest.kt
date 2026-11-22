package org.vrpassthroughplayer.plugin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BilibiliDanmakuTest {
    @Test fun absoluteTimeDefinesSegmentAndZeroIsValid() {
        val data = entry(1, 360_000, "下一段 ꞏ 雨") + entry(2, 0, "片头") + entry(3, 359_999, "边界")
        assertEquals(listOf(0, 359_999), BilibiliDanmaku.decode(data, 1).map { it.time })
        val next = BilibiliDanmaku.decode(data, 2).single()
        assertEquals(360_000, next.time)
        assertEquals("下一段 ꞏ 雨", next.text)
        assertEquals(0x12abef, next.color)
    }

    @Test fun everyOrdinaryTextCommentOfABurstIsReturned() {
        val data = entry(1, 6, "先\n说") + entry(2, 15, "第二条") + entry(3, 20, "最后") +
            entry(3, 251, "重复") + entry(4, 251, "高级", mode = 7) + entry(5, 252, "特殊", pool = 1) +
            entry(6, 253, " ")
        assertEquals(listOf("先 说", "第二条", "最后"), BilibiliDanmaku.decode(data, 1).map { it.text })
        assertEquals(emptyList<BilibiliDanmaku.Comment>(), BilibiliDanmaku.decode(data + field(2, 1), 1))
    }

    @Test fun truncatedMessageIsRejected() {
        val data = entry(1, 50, "有字")
        assertTrue(runCatching { BilibiliDanmaku.decode(data.copyOf(data.size - 1), 1) }.isFailure)
    }

    @Test fun colorsArePreservedIncludingProtobufDefaultBlack() {
        val data = entry(1, 10, "红", color = 0xff0000) + entry(2, 400, "蓝", color = 0x0000ff) +
            entry(3, 700, "黑", color = 0) + entry(4, 1000, "白", color = 0xffffff)
        assertEquals(listOf(0xff0000, 0x0000ff, 0, 0xffffff), BilibiliDanmaku.decode(data, 1).map { it.color })
    }

    private fun entry(id: Int, time: Int, text: String, mode: Int = 1, pool: Int = 0, color: Int = 0x12abef): ByteArray {
        val content = text.toByteArray()
        val message = field(1, id) + (if (time == 0) ByteArray(0) else field(2, time)) + field(3, mode) +
            (if (color == 0) ByteArray(0) else field(5, color)) + varint(58) + varint(content.size) + content + field(11, pool)
        return varint(10) + varint(message.size) + message
    }

    private fun field(number: Int, value: Int) = varint(number * 8) + varint(value)

    private fun varint(value: Int): ByteArray {
        var remaining = value
        val bytes = ArrayList<Byte>()
        while (remaining >= 128) {
            bytes.add(((remaining and 127) or 128).toByte())
            remaining = remaining ushr 7
        }
        bytes.add(remaining.toByte())
        return bytes.toByteArray()
    }
}
