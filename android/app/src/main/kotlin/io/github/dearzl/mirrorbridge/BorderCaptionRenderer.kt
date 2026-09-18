package io.github.dearzl.mirrorbridge

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import java.io.File

/** EXIF drawn directly on the existing template canvas; never adds another frame. */
object BorderCaptionRenderer {
    data class Caption(val text: String, val layout: StaticLayout, val padding: Int) {
        val height: Int
            get() = layout.height + padding * 2
    }

    fun shutter(value: String?): String {
        val raw = value.orEmpty().trim().removeSuffix("s").trim()
        if (raw.isEmpty()) return "未知"
        val parts = raw.split('/')
        val seconds = if (parts.size == 2) {
            val numerator = parts[0].toDoubleOrNull()
            val denominator = parts[1].toDoubleOrNull()
            if (numerator != null && denominator != null && denominator > 0) numerator / denominator else null
        } else raw.toDoubleOrNull()
        if (seconds == null || !seconds.isFinite() || seconds <= 0) return raw
        if (seconds < 1) {
            // 1/3 EV nominal shutter labels, including fractional denominators.
            // https://www.scantips.com/lights/fstop2.html
            val denominators = listOf(1.3, 1.6, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0,
                8.0, 10.0, 13.0, 15.0, 20.0, 25.0, 30.0, 40.0, 50.0, 60.0,
                80.0, 100.0, 125.0, 160.0, 200.0, 250.0, 320.0, 400.0,
                500.0, 640.0, 800.0, 1000.0, 1250.0, 1600.0, 2000.0,
                2500.0, 3200.0, 4000.0, 5000.0, 6400.0, 8000.0,
                10000.0, 12800.0, 16000.0, 20000.0, 25600.0, 32000.0)
            val reciprocal = 1 / seconds
            val nominal = denominators.minBy { kotlin.math.abs(kotlin.math.ln(it / reciprocal)) }
            // Allow EXIF rounding within half a 1/3 EV step. Outside the table,
            // retain the computed denominator instead of inventing a camera setting.
            val denominator = if (kotlin.math.abs(kotlin.math.ln(nominal / reciprocal)) <= kotlin.math.ln(2.0) / 6) nominal else reciprocal
            return "1/" + java.math.BigDecimal.valueOf(denominator).setScale(2, java.math.RoundingMode.HALF_UP).stripTrailingZeros().toPlainString() + "s"
        }
        val nominal = listOf(1.0,1.3,1.6,2.0,2.5,3.0,4.0,5.0,6.0,8.0,10.0,13.0,15.0,20.0,25.0,30.0,40.0,50.0,60.0,80.0,100.0,125.0,160.0,200.0,250.0,320.0,400.0,500.0,640.0,800.0,1000.0).minBy { kotlin.math.abs(kotlin.math.ln(it / seconds)) }
        return java.math.BigDecimal.valueOf(nominal).stripTrailingZeros().toPlainString() + "s"
    }

    fun fields(exif: Map<String, String>): List<String> =
        listOf(
            "机型：${exif["Model"].orEmpty().ifBlank { "未知" }}",
            "快门：${shutter(exif["ExposureTime"])}",
            "光圈：${exif["FNumber"].orEmpty().ifBlank { "未知" }}",
            "ISO：${(exif["PhotographicSensitivity"] ?: exif["ISOSpeedRatings"]).orEmpty().ifBlank { "未知" }}",
            "拍摄时间：${exif["DateTimeOriginal"].orEmpty().ifBlank { "未知" }}",
        )

    fun measure(width: Int, exif: Map<String, String>, dark: Boolean, scale: Float = 1f, alignment: String = "center"): Caption {
        require(width > 0)
        val padding = (width * .035f).toInt().coerceAtLeast(1).coerceAtMost((width - 1) / 2)
        val paint =
            TextPaint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                color = if (dark) Color.WHITE else Color.rgb(35, 35, 38)
                textSize = (width * .019f * scale.coerceIn(.5f, 2f)).coerceAtLeast(8f)
                typeface = Typeface.create("sans-serif", Typeface.NORMAL)
            }
        val values = fields(exif)
        val text = values[0].removePrefix("机型：") + "\n" +
            values[1].removePrefix("快门：") + "   ·   f/" +
            values[2].removePrefix("光圈：") + "   ·   " + values[3].replace("ISO：", "ISO ") +
            "\n" + values[4].removePrefix("拍摄时间：")
        val layout =
            StaticLayout.Builder.obtain(
                    text,
                    0,
                    text.length,
                    paint,
                    (width - padding * 2).coerceAtLeast(1),
                )
                .setAlignment(when (alignment) { "left" -> Layout.Alignment.ALIGN_NORMAL; "right" -> Layout.Alignment.ALIGN_OPPOSITE; else -> Layout.Alignment.ALIGN_CENTER })
                .setIncludePad(true)
                .setLineSpacing(paint.textSize * .22f, 1f)
                .setBreakStrategy(Layout.BREAK_STRATEGY_HIGH_QUALITY)
                .build()
        return Caption(text, layout, padding)
    }

    fun append(source: File, output: File, template: String, exif: Map<String, String>, x: Float = .5f, y: Float = 1f, scale: Float = 1f, alignment: String = "center"): String {
        val bitmap = BitmapFactory.decodeFile(source.path) ?: error("无法读取边框图片")
        val dark = template in setOf("night_frame", "film_contact", "focus_grid")
        try {
            val textWidth = (bitmap.width * .85f).toInt().coerceAtLeast(1)
            var caption = measure(textWidth, exif, dark, scale, alignment)
            // Keep all wrapped lines inside even for unusually long metadata.
            if (caption.height > bitmap.height) caption = measure(textWidth, exif, dark, .5f, alignment)
            val composed =
                Bitmap.createBitmap(
                    bitmap.width,
                    bitmap.height,
                    Bitmap.Config.ARGB_8888,
                )
            try {
                val canvas = Canvas(composed)
                canvas.drawColor(if (dark) Color.rgb(18, 18, 20) else Color.WHITE)
                canvas.drawBitmap(bitmap, 0f, 0f, null)
                canvas.save()
                canvas.translate(
                    (bitmap.width - textWidth) * x.coerceIn(0f, 1f) + caption.padding,
                    ((bitmap.height - caption.layout.height - caption.padding * 2).coerceAtLeast(0) * y.coerceIn(0f, 1f) + caption.padding).toFloat(),
                )
                caption.layout.draw(canvas)
                canvas.restore()
                output.outputStream().use {
                    check(composed.compress(Bitmap.CompressFormat.JPEG, 100, it))
                }
                val metadata = android.media.ExifInterface(output.path)
                for (key in
                    listOf(
                        "Make",
                        "Model",
                        "LensModel",
                        "ExposureTime",
                        "FNumber",
                        "PhotographicSensitivity",
                        "ISOSpeedRatings",
                        "FocalLength",
                        "DateTimeOriginal",
                        "DateTime",
                        "Artist",
                        "Copyright",
                    )) {
                    exif[key]?.let { value -> runCatching { metadata.setAttribute(key, value) } }
                }
                metadata.setAttribute("Orientation", "1")
                metadata.setAttribute("ImageWidth", composed.width.toString())
                metadata.setAttribute("ImageLength", composed.height.toString())
                metadata.saveAttributes()
                return output.path
            } finally {
                composed.recycle()
            }
        } finally {
            bitmap.recycle()
        }
    }
}
