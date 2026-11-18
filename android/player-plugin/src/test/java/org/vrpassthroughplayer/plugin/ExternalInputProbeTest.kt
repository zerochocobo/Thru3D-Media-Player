package org.vrpassthroughplayer.plugin

import android.view.InputDevice
import org.junit.Assert.assertEquals
import org.junit.Test

class ExternalInputProbeTest {
    @Test fun sourcesNameEveryFullClass() {
        assertEquals("[\"gamepad\",\"joystick\"]", ExternalInputProbe.sourceNames(InputDevice.SOURCE_GAMEPAD or InputDevice.SOURCE_JOYSTICK).toString())
        // DPAD shares the button class bit with KEYBOARD; only the full mask names a keyboard.
        assertEquals("[\"dpad\"]", ExternalInputProbe.sourceNames(InputDevice.SOURCE_DPAD).toString())
        assertEquals("[\"keyboard\"]", ExternalInputProbe.sourceNames(InputDevice.SOURCE_KEYBOARD).toString())
        assertEquals("[]", ExternalInputProbe.sourceNames(0).toString())
    }

    @Test fun printingKeysAreWithheld() {
        assertEquals("printable", ExternalInputProbe.keyCode("KEYCODE_A", true))
        assertEquals("1001", ExternalInputProbe.keyCode("1001", false))
        assertEquals("KEYCODE_VOLUME_UP", ExternalInputProbe.keyCode("KEYCODE_VOLUME_UP", false))
    }

    @Test fun axesUseHysteresis() {
        var state = 0
        val states = ArrayList<Int>()
        for (value in floatArrayOf(0.1f, 0.7f, 0.55f, 0.45f, 0.3f, -0.9f, Float.NaN)) {
            val next = ExternalInputProbe.axisState(state, value)
            if (next != state) states.add(next)
            state = next
        }
        assertEquals(listOf(1, 0, -1, 0), states)
    }
}
