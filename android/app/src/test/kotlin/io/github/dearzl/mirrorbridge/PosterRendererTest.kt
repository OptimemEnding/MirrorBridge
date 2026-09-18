package io.github.dearzl.mirrorbridge

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import java.io.File
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class PosterRendererTest {
    @Test fun posterTextChangesQuadrantsAndExportKeepsSourceBytes() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val source = File(activity.cacheDir, "poster-source.jpg")
        val bitmap = Bitmap.createBitmap(900, 600, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.rgb(18, 40, 60))
        source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 100, it) }
        bitmap.recycle()
        val pristine = source.readBytes()
        for (position in listOf("左上", "右上", "左下", "右下")) {
            val output = File(activity.cacheDir, "poster-$position.jpg")
            EdgeWatermarkRenderer.render(source, output, "", .1f, false, null, emptyMap(),
                mapOf("poster" to mapOf("title" to "WORLD", "subtitle" to "CAPTURE", "position" to position,
                    "enabled" to true, "layout" to "poster")))
            val result = BitmapFactory.decodeFile(output.path)
            assertEquals(900, result.width)
            assertEquals(600, result.height)
            val bright = IntArray(4)
            for (y in 0 until result.height) for (x in 0 until result.width) {
                val pixel = result.getPixel(x, y)
                if (Color.red(pixel) > 180 && Color.green(pixel) > 180 && Color.blue(pixel) > 180) {
                    bright[(if (y >= result.height / 2) 2 else 0) + (if (x >= result.width / 2) 1 else 0)]++
                }
            }
            val quadrant = (if (position.contains("下")) 2 else 0) + (if (position.contains("右")) 1 else 0)
            assertTrue("Text must appear in $position: ${bright.toList()}", bright[quadrant] > 100)
            assertEquals(0, bright[(quadrant + 2) % 4])
            assertArrayEquals(pristine, source.readBytes())
            result.recycle()
        }
        activity.finish()
    }
}
