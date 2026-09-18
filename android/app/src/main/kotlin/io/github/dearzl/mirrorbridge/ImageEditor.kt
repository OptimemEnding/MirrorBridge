package io.github.dearzl.mirrorbridge

import android.content.Context
import java.io.File

class ImageEditor(private val context: Context) {
    fun render(
        path: String,
        lut: String?,
        intensity: Float,
        template: String?,
        spacing: Float,
        details: Boolean,
        maxDimension: Int?,
        exif: Map<String, String>,
        captionStyles: Map<String, Map<String, Any?>> = emptyMap(),
    ): String {
        val cube = lut?.takeIf { it.isNotEmpty() && intensity > 0f }?.let {
            CubeLut.load(context, it)
        }
        val directory = File(context.cacheDir, "editor_render").apply { mkdirs() }
        val output = File.createTempFile("preview_", ".jpg", directory)
        return try {
            EdgeWatermarkRenderer.render(
                File(path), output, template.orEmpty(), spacing, details,
                maxDimension, exif, captionStyles, cube, intensity.coerceIn(0f, 1f),
            )
        } catch (error: Throwable) {
            output.delete()
            throw error
        }
    }

    fun capabilities(): Map<String, Any> = mapOf(
        "component" to "MirrorBridge ImageEditor",
        "cube" to "3D trilinear",
        "templates" to TEMPLATES.toList(),
        "singleEncode" to true,
        "sourceReadOnly" to true,
    )

    companion object {
        val TEMPLATES = linkedSetOf(
            "clean_white", "night_frame", "gallery_label", "soft_shadow", "film_contact",
            "minimal_line", "studio_card", "focus_grid", "wide_caption", "compact_caption", "rounded",
        )
    }
}
