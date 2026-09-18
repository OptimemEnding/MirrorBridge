package io.github.dearzl.mirrorbridge

import android.graphics.Bitmap
import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class LiveJpegDecoderTest {
    private fun jpeg(width: Int, height: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(0xff3d7ab8.toInt())
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG,95,out)
        bitmap.recycle()
        return out.toByteArray()
    }
    @Test fun reusesFullResolutionBitmapAndHandlesCameraResolutionChanges() {
        val decoder = LiveJpegDecoder()
        val small = jpeg(640,424); val large = jpeg(1024,680)
        val first = decoder.decode(small)
        repeat(60) { assertSame(first,decoder.decode(small)) }
        assertEquals(1,decoder.allocations)
        val next = decoder.decode(large)!!
        assertEquals(1024,next.width); assertEquals(680,next.height)
        repeat(60) { assertSame(next,decoder.decode(large)) }
        assertEquals(2,decoder.allocations)
        val reduced = decoder.decode(small)!!
        assertEquals(640,reduced.width); assertEquals(424,reduced.height)
        decoder.close(); assertTrue(reduced.isRecycled)
    }
    @Test fun invalidFrameDoesNotPoisonTheNextValidFrame() {
        val decoder = LiveJpegDecoder()
        val valid = jpeg(1024,680)
        val first = decoder.decode(valid)!!
        // Has SOI/EOI, but is not decodable JPEG: marker checks alone are insufficient.
        val invalid = byteArrayOf(0xff.toByte(),0xd8.toByte(),1,2,0xff.toByte(),0xd9.toByte())
        repeat(3) { assertNull(decoder.decode(invalid)) }
        val recovered = decoder.decode(valid)!!
        assertSame(first,recovered)
        assertEquals(1024,recovered.width)
        assertEquals(1,decoder.allocations)
        decoder.close()
    }

}
