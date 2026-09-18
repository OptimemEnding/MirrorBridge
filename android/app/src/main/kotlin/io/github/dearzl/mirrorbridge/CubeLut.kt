package io.github.dearzl.mirrorbridge

import android.content.Context
import java.io.File

data class CubeLut(
    val size: Int,
    val values: FloatArray,
    val domainMin: FloatArray,
    val domainMax: FloatArray,
) {
    companion object {
        private const val MAX_TEXT_CHARS = 64 * 1024 * 1024
        private val numeric = Regex("[-+]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][-+]?\\d+)?")

        fun parse(text: String): CubeLut {
            require(text.isNotEmpty() && text.length <= MAX_TEXT_CHARS) {
                "Cube 文件为空或超过 64 MB"
            }
            var size = 0
            var sizeSeen = false
            var titleSeen = false
            var domainMinSeen = false
            var domainMaxSeen = false
            var dataStarted = false
            var domainMin = floatArrayOf(0f, 0f, 0f)
            var domainMax = floatArrayOf(1f, 1f, 1f)
            val rgb = ArrayList<Float>()

            text.lineSequence().forEachIndexed { index, rawLine ->
                val line = rawLine.removePrefix("\uFEFF").substringBefore('#').trim()
                if (line.isEmpty()) return@forEachIndexed
                val fields = line.split(Regex("\\s+"))
                fun number(value: String, label: String): Float {
                    require(numeric.matches(value)) { "$label is invalid at line ${index + 1}" }
                    return value.toFloat().also {
                        require(it.isFinite()) { "$label is not finite at line ${index + 1}" }
                    }
                }
                fun triple(name: String): FloatArray {
                    require(fields.size == 4) { "$name must contain three values at line ${index + 1}" }
                    return fields.drop(1).map { number(it, name) }.toFloatArray()
                }
                when (fields[0]) {
                    "LUT_3D_SIZE" -> {
                        require(fields.size == 2 && !sizeSeen && !dataStarted) {
                            "Cube size is invalid at line ${index + 1}"
                        }
                        size = fields[1].toIntOrNull() ?: 0
                        sizeSeen = true
                    }
                    "TITLE" -> {
                        require(!titleSeen) { "TITLE is repeated at line ${index + 1}" }
                        val title = line.removePrefix("TITLE").trim()
                        require(title.length >= 2 && title.first() == '"' && title.last() == '"') {
                            "TITLE must be quoted at line ${index + 1}"
                        }
                        titleSeen = true
                    }
                    "DOMAIN_MIN" -> {
                        require(!domainMinSeen && !dataStarted) { "DOMAIN_MIN is repeated or misplaced at line ${index + 1}" }
                        domainMin = triple("DOMAIN_MIN")
                        domainMinSeen = true
                    }
                    "DOMAIN_MAX" -> {
                        require(!domainMaxSeen && !dataStarted) { "DOMAIN_MAX is repeated or misplaced at line ${index + 1}" }
                        domainMax = triple("DOMAIN_MAX")
                        domainMaxSeen = true
                    }
                    "LUT_1D_SIZE" -> error("Only 3D Cube LUT files are supported")
                    else -> {
                        require(sizeSeen && fields.size == 3) { "Cube data row is invalid at line ${index + 1}" }
                        val row = fields.map { number(it, "Cube data") }
                        require(row.all { it in 0f..1f }) { "Cube data must be between 0 and 1 at line ${index + 1}" }
                        rgb.addAll(row)
                        dataStarted = true
                    }
                }
            }

            require(sizeSeen && size in 2..65) { "Cube size must be between 2 and 65" }
            require(rgb.size == size * size * size * 3) { "Cube size does not match its data rows" }
            require(domainMin.indices.all {
                domainMin[it].isFinite() && domainMax[it].isFinite() && domainMax[it] > domainMin[it]
            }) { "Cube domain is invalid" }
            require(rgb.all(Float::isFinite)) { "Cube contains a non-finite value" }

            val rgba = FloatArray(size * size * size * 4)
            repeat(size * size * size) { index ->
                rgba[index * 4] = rgb[index * 3]
                rgba[index * 4 + 1] = rgb[index * 3 + 1]
                rgba[index * 4 + 2] = rgb[index * 3 + 2]
                rgba[index * 4 + 3] = 1f
            }
            return CubeLut(size, rgba, domainMin, domainMax)
        }

        fun load(context: Context, nameOrPath: String): CubeLut {
            val text = if (nameOrPath.startsWith('/')) {
                File(nameOrPath).readText()
            } else {
                context.assets.open("luts/${nameOrPath.replace(" ", "%20")}.cube")
                    .bufferedReader().use { it.readText() }
            }
            return parse(text)
        }
    }
}
