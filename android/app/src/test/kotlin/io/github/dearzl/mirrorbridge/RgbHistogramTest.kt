package io.github.dearzl.mirrorbridge
import org.junit.Assert.*
import org.junit.Test
class RgbHistogramTest {
    @Test fun blackIsLeftWhiteIsRightAndChannelsAreIndependent() {
        val h=RgbHistogram()
        h.add(0xff000000.toInt()); h.add(0xffffffff.toInt()); h.add(0xffff8000.toInt())
        assertEquals(1,h.red[0]); assertEquals(2,h.red[255])
        assertEquals(1,h.green[0]); assertEquals(1,h.green[128]); assertEquals(1,h.green[255])
        assertEquals(2,h.blue[0]); assertEquals(1,h.blue[255])
        assertEquals(listOf(3,3,3),h.channels().map { it.sum() })
    }
}
