package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.nio.ByteBuffer
import java.nio.ByteOrder

class PersonalVoiceStoreTest {
    @get:Rule val temporary=TemporaryFolder()
    private fun reference()=temporary.newFile().apply {
        val data=ByteBuffer.allocate(576044).order(ByteOrder.LITTLE_ENDIAN)
        data.put("RIFF".toByteArray()).putInt(576036).put("WAVEfmt ".toByteArray()).putInt(16)
            .putShort(1).putShort(2).putInt(48000).putInt(192000).putShort(4).putShort(16).put("data".toByteArray()).putInt(576000)
        while(data.hasRemaining())data.putShort(1200)
        writeBytes(data.array())
    }
    private fun encoded(frames: Int=37)=temporary.newFile().apply {
        val data=ByteBuffer.allocate(12+frames*32).order(ByteOrder.LITTLE_ENDIAN);data.put("T3VOICE1".toByteArray()).putInt(frames)
        repeat(frames*16){data.putShort((it%1024).toShort())};writeBytes(data.array())
    }
    @Test fun referenceAndCodesSurviveRestartWithoutTheSourceOrCache() {
        val root=temporary.newFolder();val wav=reference();val codes=encoded();val saved=PersonalVoiceStore(root).save("日语女声",wav,codes)
        wav.delete();codes.delete()
        val reopened=PersonalVoiceStore(root);assertEquals(1,reopened.list().length());assertEquals("日语女声",reopened.list().getJSONObject(0).getString("name"))
        assertEquals(37*16,reopened.load(saved.getString("id")).size)
    }
    @Test fun renameKeepsIdentityAndCodesAndDuplicateNamesNeverOverwrite() {
        val store=PersonalVoiceStore(temporary.newFolder());val a=store.save("My Voice",reference(),encoded());val id=a.getString("id");val before=store.load(id)
        assertThrows(IllegalArgumentException::class.java){store.save(" my voice ",reference(),encoded())}
        store.rename(id,"电影女声");assertArrayEquals(before,store.load(id));assertEquals("电影女声",store.list().getJSONObject(0).getString("name"))
        for(name in listOf(" ","bad\nname","a".repeat(33)))assertThrows(IllegalArgumentException::class.java){store.rename(id,name)}
    }
    @Test fun corruptAndUncommittedEntriesAreIgnoredAndDeletionIsScoped() {
        val root=temporary.newFolder();val store=PersonalVoiceStore(root);val a=store.save("A",reference(),encoded());val b=store.save("B",reference(),encoded())
        root.resolve(".saving-interrupted").mkdir();root.resolve(a.getString("id").removePrefix("custom:")).resolve("codes.bin").writeText("corrupt")
        assertEquals(1,store.list().length());assertFalse(store.contains(a.getString("id")));store.delete(a.getString("id"));assertTrue(store.contains(b.getString("id")))
        assertThrows(IllegalArgumentException::class.java){store.delete("custom:../../escape")}
    }
    @Test fun invalidCodeShapeRangeAndTruncatedReferencesAreRejected() {
        val store=PersonalVoiceStore(temporary.newFolder())
        for(n in listOf(36,126))assertThrows(IllegalArgumentException::class.java){store.save("bad",reference(),encoded(n))}
        val codes=encoded();val bytes=codes.readBytes();bytes[12]=0;bytes[13]=4;codes.writeBytes(bytes)
        assertThrows(IllegalArgumentException::class.java){store.save("bad",reference(),codes)}
        val wav=reference();wav.appendBytes(byteArrayOf(0));assertThrows(IllegalArgumentException::class.java){store.save("bad",wav,encoded())}
        assertEquals(0,store.list().length())
    }
}
