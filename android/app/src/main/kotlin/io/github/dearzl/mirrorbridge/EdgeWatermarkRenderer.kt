package io.github.dearzl.mirrorbridge

import android.graphics.*
import androidx.exifinterface.media.ExifInterface
import java.io.File
import kotlin.math.*

/** A separate, native-resolution canvas: the source is only ever opened for reading. */
object EdgeWatermarkRenderer {
    private val isoStops = listOf(6.0,8.0,10.0,12.0,16.0,20.0,25.0,32.0,40.0,50.0,64.0,80.0,
        100.0,125.0,160.0,200.0,250.0,320.0,400.0,500.0,640.0,800.0,1000.0,1250.0,1600.0,
        2000.0,2500.0,3200.0,4000.0,5000.0,6400.0,8000.0,10000.0,12800.0,16000.0,20000.0,
        25600.0,32000.0,40000.0,51200.0,64000.0,80000.0,102400.0,128000.0,160000.0,204800.0,
        256000.0,320000.0,409600.0,512000.0,640000.0,819200.0,1024000.0,1280000.0,1638400.0,2048000.0,2560000.0,3276800.0)
    private fun nominal(value: String?, stops: List<Double>): String {
        val parts = value.orEmpty().split('/')
        val n = if (parts.size == 2) (parts[0].toDoubleOrNull() ?: 0.0) / (parts[1].toDoubleOrNull() ?: 1.0) else value?.toDoubleOrNull()
        if (n == null || n <= 0 || !n.isFinite()) return "—"
        return java.math.BigDecimal.valueOf(stops.minBy { abs(ln(it / n)) }).stripTrailingZeros().toPlainString()
    }
    fun texts(exif: Map<String, String>): Map<String, String> = mapOf(
        "model" to exif["Model"].orEmpty(),
        "time" to exif["DateTimeOriginal"].orEmpty(),
        "exposure" to listOf(BorderCaptionRenderer.shutter(exif["ExposureTime"]),
            "f/" + nominal(exif["FNumber"], listOf(.7,.8,.9,1.0,1.1,1.2,1.4,1.6,1.8,2.0,2.2,2.5,2.8,3.2,3.5,4.0,4.5,5.0,5.6,6.3,7.1,8.0,9.0,10.0,11.0,13.0,14.0,16.0,18.0,20.0,22.0,25.0,29.0,32.0,36.0,40.0,45.0,51.0,57.0,64.0)),
            "ISO " + nominal(exif["PhotographicSensitivity"] ?: exif["ISOSpeedRatings"], isoStops)).joinToString("   ·   ")
    )

    // Trilinear interpolation on decoded source rows, before the one final JPEG encode.
    internal fun applyCube(bitmap: Bitmap, cube: CubeLut, intensity: Float) {
        val row = IntArray(bitmap.width)
        val indices = Array(3) { IntArray(256) }
        val weights = Array(3) { FloatArray(256) }
        for (channel in 0..2) for (value in 0..255) {
            val position = ((value / 255f - cube.domainMin[channel]) /
                (cube.domainMax[channel] - cube.domainMin[channel])).coerceIn(0f, 1f) * (cube.size - 1)
            indices[channel][value] = position.toInt().coerceAtMost(cube.size - 2)
            weights[channel][value] = position - indices[channel][value]
        }
        for (y in 0 until bitmap.height) {
            bitmap.getPixels(row, 0, bitmap.width, 0, y, bitmap.width, 1)
            for (x in row.indices) {
                val pixel = row[x]; val r = Color.red(pixel); val g = Color.green(pixel); val b = Color.blue(pixel)
                val ri = indices[0][r]; val gi = indices[1][g]; val bi = indices[2][b]
                val rw = weights[0][r]; val gw = weights[1][g]; val bw = weights[2][b]
                var result = -0x1000000
                for (channel in 0..2) {
                    var value = 0f
                    for (dz in 0..1) for (dy in 0..1) for (dx in 0..1) {
                        val index = (((bi + dz) * cube.size + gi + dy) * cube.size + ri + dx) * 4 + channel
                        value += cube.values[index] * (if (dx == 0) 1-rw else rw) * (if (dy == 0) 1-gw else gw) * (if (dz == 0) 1-bw else bw)
                    }
                    val source = when (channel) { 0 -> r; 1 -> g; else -> b } / 255f
                    val mixed = source + (value.coerceIn(0f, 1f) - source) * intensity.coerceIn(0f, 1f)
                    result = result or ((mixed * 255).roundToInt() shl (16 - channel * 8))
                }
                row[x] = result
            }
            bitmap.setPixels(row, 0, bitmap.width, 0, y, bitmap.width, 1)
        }
    }

    internal fun drawPoster(canvas: Canvas, width: Int, height: Int, edge: Int, poster: Map<String, Any?>) {
        if (poster["enabled"] != true) return
        val title = (poster["title"] as? String).orEmpty().take(70)
        val subtitle = (poster["subtitle"] as? String).orEmpty().take(80)
        fun number(key: String, fallback: Float) = (poster[key] as? Number)?.toFloat()?.takeIf { it.isFinite() } ?: fallback
        val family = (poster["font"] as? String)?.takeIf { it in setOf("sans-serif", "serif", "monospace", "cursive") } ?: "sans-serif"
        val legacy = poster["position"] as? String ?: "左上"
        val px = number("x", if (legacy.contains("右")) .94f else .06f).coerceIn(0f, 1f)
        val py = number("y", if (legacy.contains("下")) .93f else .07f).coerceIn(0f, 1f)
        val lines = if (title.isBlank()) emptyList() else title.split('\n').take(3)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE; typeface = Typeface.create(family, Typeface.BOLD)
            textSize = width * .087f * number("scale", 1f).coerceIn(.3f, 2f)
            setShadowLayer(width * .002f, 0f, width * .001f, Color.argb(70, 0, 0, 0))
        }
        val available = canvas.width * .94f
        val maxLine = lines.maxOfOrNull { paint.measureText(it) } ?: 0f
        if (maxLine > available) paint.textSize *= available / maxLine
        val titleSize = paint.textSize
        val lineHeight = titleSize * 1.1f
        val subtitlePaint = Paint(paint).apply { typeface = Typeface.create(family, Typeface.NORMAL); textSize = width * .026f * number("subtitleScale", 1f).coerceIn(.3f, 2f) }
        if (subtitlePaint.measureText(subtitle) > available) subtitlePaint.textSize *= available / subtitlePaint.measureText(subtitle)
        val blockWidth = max(lines.maxOfOrNull { paint.measureText(it) } ?: 0f, subtitlePaint.measureText(subtitle))
        val total = lines.size * lineHeight + if (subtitle.isBlank()) 0f else subtitlePaint.textSize * 1.5f
        // Flutter drags the poster over the complete rendered preview, including
        // added margins. Use the same final-canvas coordinate system here so the
        // drag handle and encoded text land at the same normalized position.
        val x = (canvas.width - blockWidth).coerceAtLeast(0f) * px
        val top = (canvas.height - total).coerceAtLeast(0f) * py
        lines.forEachIndexed { index, line -> canvas.drawText(line, x, top - paint.fontMetrics.ascent + index * lineHeight, paint) }
        if (subtitle.isNotBlank()) canvas.drawText(subtitle, x, top + lines.size * lineHeight - subtitlePaint.fontMetrics.ascent, subtitlePaint)
    }

    fun render(source: File, output: File, template: String, border: Float, details: Boolean,
        maxDimension: Int?, exif: Map<String, String>, styles: Map<String, Map<String, Any?>>,
        cube: CubeLut? = null, intensity: Float = 1f): String {
        require(source.canonicalPath != output.canonicalPath)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(source.path, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "无法读取照片" }
        val options = BitmapFactory.Options().apply {
            inSampleSize = 1
            inMutable = true
            if (maxDimension != null) while (max(bounds.outWidth, bounds.outHeight) / (inSampleSize * 2) >= maxDimension) inSampleSize *= 2
        }
        var bitmap = BitmapFactory.decodeFile(source.path, options) ?: error("无法解码照片")
        try {
            val orientation = ExifInterface(source.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1)
            val matrix = Matrix().apply {
                when (orientation) {
                    2 -> setScale(-1f, 1f)
                    3 -> setRotate(180f)
                    4 -> setScale(1f, -1f)
                    5 -> { setRotate(90f); postScale(-1f, 1f) }
                    6 -> setRotate(90f)
                    7 -> { setRotate(-90f); postScale(-1f, 1f) }
                    8 -> setRotate(-90f)
                }
            }
            if (!matrix.isIdentity) {
                val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, false)
                if (rotated !== bitmap) { bitmap.recycle(); bitmap = rotated }
            }
            val turns = ((styles["poster"]?.get("rotation") as? Number)?.toInt() ?: 0).mod(4)
            if (turns != 0) {
                val rotated = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, Matrix().apply { setRotate(turns * 90f) }, false)
                if (rotated !== bitmap) { bitmap.recycle(); bitmap = rotated }
            }
            // Preview alone may be reduced. Export has no maxDimension and preserves every source pixel.
            if (maxDimension != null && max(bitmap.width, bitmap.height) > maxDimension) {
                val ratio = maxDimension.toFloat() / max(bitmap.width, bitmap.height)
                val scaled = Bitmap.createScaledBitmap(bitmap, (bitmap.width * ratio).roundToInt().coerceAtLeast(1), (bitmap.height * ratio).roundToInt().coerceAtLeast(1), true)
                if (scaled !== bitmap) { bitmap.recycle(); bitmap = scaled }
            }
            if (cube != null) {
                if (!bitmap.isMutable) {
                    val mutable = bitmap.copy(Bitmap.Config.ARGB_8888, true) ?: error("无法分配图像内存")
                    bitmap.recycle(); bitmap = mutable
                }
                applyCube(bitmap, cube, intensity)
            }
            val edge = if (template.isEmpty()) 0 else (min(bitmap.width, bitmap.height) * (.045f + border.coerceIn(0f, 1f) * .12f)).roundToInt().coerceAtLeast(1)
            val band = if (edge == 0) 0 else max(edge, (bitmap.width * .15f).roundToInt())
            // With no border the decoded bitmap is already the final canvas. Reusing
            // it avoids allocating a second full-resolution ARGB bitmap during export.
            val composed = if (edge == 0) bitmap else Bitmap.createBitmap(
                bitmap.width + edge * 2,
                bitmap.height + edge + band,
                Bitmap.Config.ARGB_8888,
            )
            try {
                val canvas = Canvas(composed)
                val dark = template in setOf("night_frame", "film_contact", "focus_grid")
                if (edge != 0) {
                    canvas.drawColor(when (template) {
                        "night_frame", "film_contact", "focus_grid" -> Color.rgb(20,22,26)
                        "gallery_label" -> Color.rgb(246,242,234)
                        "soft_shadow" -> Color.rgb(235,238,240)
                        else -> Color.WHITE
                    })
                    val decoration = Paint(Paint.ANTI_ALIAS_FLAG)
                    if (template in setOf("soft_shadow", "studio_card", "wide_caption", "compact_caption")) {
                        // A low-resolution backdrop affects only newly added margins.
                        val small = Bitmap.createScaledBitmap(bitmap, 12, 12, true)
                        decoration.isFilterBitmap = true
                        canvas.drawBitmap(small, null, Rect(0, 0, composed.width, composed.height), decoration)
                        small.recycle()
                        canvas.drawColor(Color.argb(if (template == "soft_shadow") 190 else 225, 255, 255, 255))
                        if (template == "studio_card" || template == "compact_caption") {
                            decoration.color = Color.argb(180,255,255,255)
                            canvas.drawRoundRect(edge * .5f, (edge + bitmap.height + band * .08f), composed.width - edge * .5f,
                                composed.height - band * .08f, edge * .25f, edge * .25f, decoration)
                        }
                    }
                    if (template == "focus_grid" || template == "film_contact") {
                        decoration.color = Color.rgb(43,46,51); decoration.strokeWidth = 1f
                        val spacing = max(8, edge / 2)
                        for (x in 0 until composed.width step spacing) canvas.drawLine(x.toFloat(), 0f, x.toFloat(), composed.height.toFloat(), decoration)
                        for (y in 0 until composed.height step spacing) canvas.drawLine(0f, y.toFloat(), composed.width.toFloat(), y.toFloat(), decoration)
                    }
                    if (template == "minimal_line" || template == "gallery_label") {
                        decoration.color = Color.rgb(208,205,198); decoration.strokeWidth = max(1f, bitmap.width / 1200f)
                        val lineY = edge + bitmap.height + band * .08f
                        canvas.drawLine(edge.toFloat(), lineY, (edge + bitmap.width).toFloat(), lineY, decoration)
                    }
                    if (template == "rounded") {
                        canvas.save()
                        val path = Path().apply { addRoundRect(RectF(edge.toFloat(), edge.toFloat(), (edge + bitmap.width).toFloat(), (edge + bitmap.height).toFloat()), bitmap.width * .035f, bitmap.width * .035f, Path.Direction.CW) }
                        canvas.clipPath(path)
                        canvas.drawBitmap(bitmap, edge.toFloat(), edge.toFloat(), null)
                        canvas.restore()
                    } else canvas.drawBitmap(bitmap, edge.toFloat(), edge.toFloat(), null)
                }
                drawPoster(canvas, bitmap.width, bitmap.height, edge, styles["poster"].orEmpty())
                if (details) {
                    val defaults = mapOf("model" to .18f, "exposure" to .50f, "time" to .82f)
                    for ((key, text) in texts(exif)) {
                        if (text.isBlank()) continue
                        val style = styles[key].orEmpty()
                        if (style["enabled"] == false) continue
                        fun number(name: String, fallback: Float) = (style[name] as? Number)?.toFloat()?.takeIf { it.isFinite() } ?: fallback
                        val family = (style["font"] as? String)?.takeIf { it in setOf("sans-serif", "sans-serif-light", "sans-serif-condensed", "serif", "monospace", "cursive", "casual") } ?: "sans-serif"
                        val face = (if (style["bold"] == true) Typeface.BOLD else 0) or (if (style["italic"] == true) Typeface.ITALIC else 0)
                        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                            color = if (dark || edge == 0) Color.WHITE else Color.rgb(32,34,38)
                            textSize = bitmap.width * .021f * number("scale", 1f).coerceIn(.5f, 2f)
                            typeface = Typeface.create(family, face)
                        }
                        // Positions are confined to the added edge, never the photograph.
                        val available = composed.width - edge * 2f
                        if (paint.measureText(text) > available) paint.textSize *= available / paint.measureText(text)
                        val x = edge + (available - paint.measureText(text)) * number("x", .5f).coerceIn(0f, 1f)
                        val top = style["edge"] == "top"
                        val h = if (edge == 0) bitmap.height * .15f else if (top) edge.toFloat() else band.toFloat()
                        val origin = if (top) 0f else if (edge == 0) bitmap.height - h else (edge + bitmap.height).toFloat()
                        val textHeight = paint.fontMetrics.bottom - paint.fontMetrics.top
                        if (textHeight > h * .9f) paint.textSize *= h * .9f / textHeight
                        val fm = paint.fontMetrics
                        val y = origin - fm.top + (h - (fm.bottom - fm.top)).coerceAtLeast(0f) * number("y", defaults[key]!!).coerceIn(0f, 1f)
                        canvas.save()
                        canvas.clipRect(0f, origin, composed.width.toFloat(), origin + h)
                        canvas.drawText(text, x, y, paint)
                        canvas.restore()
                    }
                }
                output.parentFile?.mkdirs()
                output.outputStream().use { check(composed.compress(Bitmap.CompressFormat.JPEG, 100, it)) }
                val metadata = ExifInterface(output.path)
                for (key in listOf("Make","Model","LensModel","ExposureTime","FNumber","PhotographicSensitivity","ISOSpeedRatings","FocalLength","DateTimeOriginal","DateTime","Artist","Copyright")) exif[key]?.let { runCatching { metadata.setAttribute(key, it) } }
                metadata.setAttribute("Orientation", "1")
                metadata.setAttribute("ImageWidth", composed.width.toString())
                metadata.setAttribute("ImageLength", composed.height.toString())
                metadata.saveAttributes()
                return output.path
            } finally { if (composed !== bitmap) composed.recycle() }
        } finally { bitmap.recycle() }
    }
}
