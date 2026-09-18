package io.github.dearzl.mirrorbridge

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.media.ExifInterface
import java.io.File
import java.security.MessageDigest
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
class EdgeWatermarkRendererTest {
    @Test fun sourceBytesAndFullImageGeometrySurviveEveryTemplateAndFont() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val source = File(activity.cacheDir, "source.jpg")
        val image = Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888)
        image.eraseColor(Color.rgb(30, 120, 210))
        source.outputStream().use { image.compress(Bitmap.CompressFormat.JPEG, 100, it) }
        image.recycle()
        val pristine = source.readBytes()
        val digest = MessageDigest.getInstance("SHA-256").digest(pristine)
        val meta = mapOf("Model" to "Nikon Z 8", "ExposureTime" to "0.0078125", "FNumber" to "3.56", "PhotographicSensitivity" to "397", "DateTimeOriginal" to "2026:09:12 10:07:40")
        for ((i, template) in ImageEditor.TEMPLATES.withIndex()) {
            val output = File(activity.cacheDir, "deleted-parent-$i/render.jpg")
            EdgeWatermarkRenderer.render(source, output, template, .5f, true, null, meta,
                mapOf("model" to mapOf("font" to listOf("cursive", "serif", "casual", "monospace")[i % 4], "bold" to true, "italic" to true, "x" to .2, "y" to .4)))
            val decoded = BitmapFactory.decodeFile(output.path)
            assertEquals(684, decoded.width)
            assertEquals(532, decoded.height)
            val pixel = decoded.getPixel(42 + 300, 42 + 200)
            assertTrue(kotlin.math.abs(Color.blue(pixel) - 210) <= 3)
            decoded.recycle()
            assertArrayEquals(digest, MessageDigest.getInstance("SHA-256").digest(source.readBytes()))
            assertEquals("Nikon Z 8", ExifInterface(output.path).getAttribute("Model"))
        }
        assertEquals("1/125s   ·   f/3.5   ·   ISO 400", EdgeWatermarkRenderer.texts(meta)["exposure"])
        activity.finish()
    }

    @Test fun identityLutPreservesPixelsAndChannelSwapIsInterpolated() {
        val values = FloatArray(2 * 2 * 2 * 4)
        for (b in 0..1) for (g in 0..1) for (r in 0..1) {
            val i = ((b * 2 + g) * 2 + r) * 4
            values[i] = r.toFloat(); values[i+1] = g.toFloat(); values[i+2] = b.toFloat(); values[i+3] = 1f
        }
        val bitmap = Bitmap.createBitmap(1,1,Bitmap.Config.ARGB_8888)
        bitmap.setPixel(0,0,Color.rgb(40,120,230))
        val cube = CubeLut(2, values, floatArrayOf(0f,0f,0f), floatArrayOf(1f,1f,1f))
        EdgeWatermarkRenderer.applyCube(bitmap, cube, 1f)
        assertEquals(Color.rgb(40,120,230),bitmap.getPixel(0,0))
        for (i in 0 until 8) { val tmp=values[i*4]; values[i*4]=values[i*4+2]; values[i*4+2]=tmp }
        EdgeWatermarkRenderer.applyCube(bitmap,cube, 1f)
        assertEquals(Color.rgb(230,120,40),bitmap.getPixel(0,0))
        bitmap.recycle()
    }

    @Test fun domainMappingAndIntensityEndpointsAreApplied() {
        val values = FloatArray(32)
        for (b in 0..1) for (g in 0..1) for (r in 0..1) {
            val index = ((b * 2 + g) * 2 + r) * 4
            values[index] = r.toFloat()
            values[index + 1] = g.toFloat()
            values[index + 2] = b.toFloat()
            values[index + 3] = 1f
        }
        val cube = CubeLut(
            2,
            values,
            floatArrayOf(.25f, .25f, .25f),
            floatArrayOf(.75f, .75f, .75f),
        )
        val bitmap = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
        val source = Color.rgb(64, 128, 191)

        bitmap.setPixel(0, 0, source)
        EdgeWatermarkRenderer.applyCube(bitmap, cube, 0f)
        assertEquals(source, bitmap.getPixel(0, 0))

        EdgeWatermarkRenderer.applyCube(bitmap, cube, 1f)
        val mapped = bitmap.getPixel(0, 0)
        assertEquals(1, Color.red(mapped))
        assertEquals(129, Color.green(mapped))
        assertEquals(255, Color.blue(mapped))
        bitmap.recycle()
    }

    @Test fun previewOnlyIsReducedAndOrientationAppliedOnce() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val source = File(activity.cacheDir, "rotate.jpg")
        val image = Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888)
        source.outputStream().use { image.compress(Bitmap.CompressFormat.JPEG, 100, it) }; image.recycle()
        ExifInterface(source.path).apply { setAttribute("Orientation", "6"); saveAttributes() }
        val sourceBytes = source.readBytes()
        for ((limit, expected) in listOf(null to (400 to 600), 300 to (200 to 300))) {
            val output = File(activity.cacheDir, "result-$limit.jpg")
            val values = FloatArray(32)
            for (b in 0..1) for (g in 0..1) for (r in 0..1) {
                val i = ((b * 2 + g) * 2 + r) * 4
                values[i] = r.toFloat(); values[i+1] = g.toFloat(); values[i+2] = b.toFloat(); values[i+3] = 1f
            }
            val cube = CubeLut(2, values, floatArrayOf(0f,0f,0f), floatArrayOf(1f,1f,1f))
            EdgeWatermarkRenderer.render(source, output, "", 0f, false, limit, emptyMap(), emptyMap(), cube)
            val decoded = BitmapFactory.decodeFile(output.path)
            assertEquals(expected.first, decoded.width); assertEquals(expected.second, decoded.height)
            assertEquals("1", ExifInterface(output.path).getAttribute("Orientation"))
            decoded.recycle()
        }
        assertArrayEquals(sourceBytes, source.readBytes())
        activity.finish()
    }
}
