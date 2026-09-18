package io.github.dearzl.mirrorbridge

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.nio.ByteBuffer
import io.flutter.plugin.common.BinaryMessenger
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
class EditorContinuityTest {
    @Test fun suppliedNikonLensIsReadWithoutNulPadding() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val file = File(activity.filesDir, "nikon-exif.jpg")
        javaClass.getResourceAsStream("/nikon-z8-exif.jpg")!!.use { input -> file.outputStream().use { input.copyTo(it) } }
        val actual = System.getenv("MIRRORBRIDGE_EXIF_FIXTURE")?.let { File(it) } ?: file
        val before = actual.readBytes()
        val library = PhoneMediaLibrary(activity, object : BinaryMessenger {
            override fun send(channel: String, message: ByteBuffer?) {}
            override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) { callback?.reply(null) }
            override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
        }, {})
        val fallback = library.parseExifFallback(before)
        assertEquals("NIKKOR Z 24-120mm f/4 S", fallback["LensModel"])
        val exif = library.exif(actual.path)
        assertEquals("NIKKOR Z 24-120mm f/4 S", exif["LensModel"])
        assertEquals("NIKON Z 8", exif["Model"])
        assertArrayEquals(before, actual.readBytes())
        println("EXIF fixture=${actual.path}; LensModel=${exif["LensModel"]}; source unchanged")
        activity.finish()
    }

    @Test fun portraitCompareBordersRotationAndLutShareGeometryWithoutChangingSource() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val source = File(activity.cacheDir, "portrait.jpg")
        val bitmap = Bitmap.createBitmap(600, 400, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.rgb(40, 100, 210))
        source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 100, it) }
        bitmap.recycle()
        ExifInterface(source.path).apply { setAttribute("Orientation", "6"); saveAttributes() }
        val pristine = source.readBytes()
        val cubeValues = FloatArray(32)
        for (b in 0..1) for (g in 0..1) for (r in 0..1) {
            val i = ((b * 2 + g) * 2 + r) * 4
            cubeValues[i] = b.toFloat(); cubeValues[i + 1] = g.toFloat(); cubeValues[i + 2] = r.toFloat(); cubeValues[i + 3] = 1f
        }
        val cube = CubeLut(2, cubeValues, floatArrayOf(0f,0f,0f), floatArrayOf(1f,1f,1f))
        val borderDigests = mutableSetOf<Int>()
        for (template in listOf("") + ImageEditor.TEMPLATES) for (rotation in 0..3) {
            fun render(compare: Boolean): Bitmap {
                val output = File(activity.cacheDir, "render-$compare.jpg")
                EdgeWatermarkRenderer.render(source, output, template, .3f, !compare, null,
                    mapOf("Model" to "Nikon Z 8"), mapOf("poster" to mapOf("rotation" to rotation,
                    "title" to "TEXT", "enabled" to !compare, "x" to .1f, "y" to .1f, "font" to "serif", "scale" to .7f)),
                    if (compare) null else cube)
                assertEquals("1", ExifInterface(output.path).getAttribute("Orientation"))
                return BitmapFactory.decodeFile(output.path)
            }
            val edited = render(false); val original = render(true)
            assertEquals(edited.width, original.width); assertEquals(edited.height, original.height)
            assertEquals(rotation % 2 == 0, edited.height > edited.width)
            if (template.isEmpty()) {
                assertEquals(if (rotation % 2 == 0) 400 else 600, edited.width)
                assertEquals(if (rotation % 2 == 0) 600 else 400, edited.height)
            } else { assertTrue(edited.width > if (rotation % 2 == 0) 400 else 600) }
            val filtered = edited.getPixel(edited.width / 2, edited.height / 2)
            val unfiltered = original.getPixel(original.width / 2, original.height / 2)
            assertTrue(Color.red(filtered) > 190); assertTrue(Color.red(unfiltered) < 60)
            if (rotation == 0) { val pixels = IntArray(edited.width * edited.height); edited.getPixels(pixels,0,edited.width,0,0,edited.width,edited.height); borderDigests.add(pixels.contentHashCode()) }
            edited.recycle(); original.recycle()
            assertArrayEquals(pristine, source.readBytes())
        }
        assertTrue("Border styles must produce distinct output", borderDigests.size >= 9)
        println("Portrait EXIF orientation, 4 manual rotations, ${ImageEditor.TEMPLATES.size} borders, compare geometry, actual LUT pixels and source integrity verified")
        activity.finish()
    }
}
