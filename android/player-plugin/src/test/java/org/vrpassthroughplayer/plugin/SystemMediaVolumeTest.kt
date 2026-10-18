package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SystemMediaVolumeTest {
    private class Device : SystemMediaVolume.Access {
        var value = SystemMediaVolume.Reading(6, 0, 15, false, false)
        val writes = mutableListOf<Triple<Int, Boolean, Boolean>>()
        var reject = false
        override fun read(): SystemMediaVolume.Reading { if (reject) error("denied"); return value }
        override fun write(index: Int, mute: Boolean, showUi: Boolean) {
            writes.add(Triple(index, mute, showUi)); value = value.copy(index = index, muted = mute)
        }
    }
    @Test fun readsActualStepsAndNeverWritesOnObservation() {
        val device = Device(); val volume = SystemMediaVolume(device)
        volume.poll()
        assertEquals(40, JSONObject(volume.status()).getInt("percent"))
        assertTrue(device.writes.isEmpty())
        device.value = device.value.copy(index = 12); volume.poll()
        assertEquals(80, JSONObject(volume.status()).getInt("percent"))
        assertTrue(device.writes.isEmpty()); volume.close()
    }
    @Test fun sliderWritesMediaStepWithSystemUiAndReadsBackQuantization() {
        val device = Device(); val volume = SystemMediaVolume(device)
        val serial = volume.set(37.0, true); volume.poll()
        assertEquals(Triple(6, false, true), device.writes.single())
        val status = JSONObject(volume.status())
        assertEquals(40, status.getInt("percent"))
        assertEquals(serial, status.getLong("write_serial")); assertTrue(status.getBoolean("write_ok"))
        volume.close()
    }
    @Test fun continuousDragCoalescesAndAcknowledgesOnlyNewestRequest() {
        val device = Device(); val volume = SystemMediaVolume(device)
        volume.set(10.0, true); volume.set(60.0, true); val serial = volume.set(90.0, true)
        volume.poll()
        assertEquals(1, device.writes.size); assertEquals(14, device.writes.single().first)
        assertEquals(serial, JSONObject(volume.status()).getLong("write_serial")); volume.close()
    }
    @Test fun nonzeroMinimumAndMuteAreHandledWithoutAssumingFifteenSteps() {
        val device = Device(); device.value = SystemMediaVolume.Reading(7, 2, 12, false, false)
        val volume = SystemMediaVolume(device)
        volume.set(0.0, true); volume.poll()
        assertEquals(Triple(2, true, true), device.writes.last())
        assertEquals(0, JSONObject(volume.status()).getInt("percent"))
        volume.set(50.0, true); volume.poll()
        assertEquals(Triple(7, false, true), device.writes.last())
        assertEquals(50, JSONObject(volume.status()).getInt("percent")); volume.close()
    }
    @Test fun fixedVolumeAndUnavailablePlatformDoNotPretendToChangeVolume() {
        val device = Device(); device.value = device.value.copy(fixed = true)
        val volume = SystemMediaVolume(device)
        volume.set(100.0, true); volume.poll()
        assertFalse(JSONObject(volume.status()).getBoolean("writable"))
        assertFalse(JSONObject(volume.status()).getBoolean("write_ok")); assertTrue(device.writes.isEmpty())
        device.reject = true; volume.poll()
        assertFalse(JSONObject(volume.status()).getBoolean("available")); volume.close()
    }
    @Test fun rejectsInvalidOrClosedRequests() {
        val volume = SystemMediaVolume(Device())
        for (value in listOf(Double.NaN, Double.POSITIVE_INFINITY, -1.0, 101.0)) assertEquals(0L, volume.set(value, true))
        volume.close(); assertEquals(0L, volume.set(50.0, true))
    }
}
