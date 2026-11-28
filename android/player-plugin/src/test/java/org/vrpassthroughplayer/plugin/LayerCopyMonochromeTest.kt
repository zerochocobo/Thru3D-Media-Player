package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class LayerCopyMonochromeTest {
    @Test fun takesTheGradeThenMonochromeFilm() {
        val look = FloatArray(34) { it.toFloat() }
        val grade = FloatArray(22) { -1f }
        LayerCopy.gradeOf(look, grade)
        assertArrayEquals(FloatArray(11) { (it + 2).toFloat() }, grade.copyOfRange(0, 11), 0f)
        assertArrayEquals(FloatArray(11) { (it + 23).toFloat() }, grade.copyOfRange(11, 22), 0f)
    }

    @Test fun settingsWithoutFilmLeaveItOff() {
        val look = FloatArray(23) { 1f }
        val grade = FloatArray(22) { -1f }
        LayerCopy.gradeOf(look, grade)
        assertArrayEquals(FloatArray(11) { 1f }, grade.copyOfRange(0, 11), 0f)
        assertArrayEquals(FloatArray(11), grade.copyOfRange(11, 22), 0f)
    }
}
