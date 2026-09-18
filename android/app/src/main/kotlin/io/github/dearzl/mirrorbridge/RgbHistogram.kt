package io.github.dearzl.mirrorbridge

/** Channel values are ordered black (0) to highlight (255). */
internal class RgbHistogram {
    val red = IntArray(256)
    val green = IntArray(256)
    val blue = IntArray(256)
    fun add(pixel: Int) {
        red[(pixel ushr 16) and 255]++
        green[(pixel ushr 8) and 255]++
        blue[pixel and 255]++
    }
    fun channels(): List<List<Int>> = listOf(red.toList(),green.toList(),blue.toList())
}
