package io.github.dearzl.mirrorbridge

import android.graphics.Bitmap
import android.graphics.BitmapFactory

/** One full-resolution mutable bitmap, retained only on the render worker. */
internal class LiveJpegDecoder {
    private var reusable: Bitmap? = null
    var allocations = 0
        private set
    fun decode(bytes: ByteArray): Bitmap? {
        val options = BitmapFactory.Options().apply {
            inMutable = true
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inSampleSize = 1
            inScaled = false
            inBitmap = reusable
        }
        var decoded = try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        } catch (_: IllegalArgumentException) {
            // The camera can change resolution when its photo/video mode changes.
            options.inBitmap = null
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        }
        // Some platform decoders return null instead of rejecting inBitmap.
        if (decoded == null && options.inBitmap != null) {
            options.inBitmap = null
            decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        }
        if (decoded == null) return null
        if (decoded !== reusable) {
            reusable?.recycle()
            allocations++
            reusable = decoded
        }
        return decoded
    }
    fun close() { reusable?.recycle(); reusable = null }
}
