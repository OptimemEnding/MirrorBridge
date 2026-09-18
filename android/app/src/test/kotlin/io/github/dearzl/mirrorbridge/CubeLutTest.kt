package io.github.dearzl.mirrorbridge

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class CubeLutTest {
    @Test fun parsesDomainAndRedFastestCubeRows() {
        val cube = CubeLut.parse(
            """
            TITLE "Test"
            LUT_3D_SIZE 2
            DOMAIN_MIN -1.0 0.0 0.25
            DOMAIN_MAX 1.0 0.5 0.75
            0.0 0.1 0.2
            0.1 0.2 0.3
            0.2 0.3 0.4
            0.3 0.4 0.5
            0.4 0.5 0.6
            0.5 0.6 0.7
            0.6 0.7 0.8
            0.7 0.8 0.9
            """.trimIndent(),
        )
        assertEquals(2, cube.size)
        assertArrayEquals(floatArrayOf(-1f, 0f, .25f), cube.domainMin, 0f)
        assertArrayEquals(floatArrayOf(1f, .5f, .75f), cube.domainMax, 0f)
        assertArrayEquals(floatArrayOf(0f, .1f, .2f, 1f), cube.values.copyOfRange(0, 4), 0f)
        assertArrayEquals(floatArrayOf(.7f, .8f, .9f, 1f), cube.values.copyOfRange(28, 32), 0f)
    }

    @Test fun rejectsIncompleteNonFiniteAndOneDimensionalFiles() {
        assertThrows(IllegalArgumentException::class.java) {
            CubeLut.parse("LUT_3D_SIZE 2\n0 0 0")
        }
        assertThrows(IllegalArgumentException::class.java) {
            CubeLut.parse(identityCube().replace("1 1 1", "NaN 1 1"))
        }
        assertThrows(IllegalStateException::class.java) {
            CubeLut.parse("LUT_1D_SIZE 2\n0 0 0\n1 1 1")
        }
    }

    @Test fun rejectsMalformedHeadersDuplicateDirectivesAndOutOfRangeRows() {
        assertThrows(IllegalArgumentException::class.java) {
            CubeLut.parse("TITLE Test\n${identityCube()}")
        }
        assertThrows(IllegalArgumentException::class.java) {
            CubeLut.parse(identityCube().replace("LUT_3D_SIZE 2", "LUT_3D_SIZE 2\nLUT_3D_SIZE 2"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            CubeLut.parse(identityCube().replace("1 1 1", "1.01 1 1"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            CubeLut.parse("LUT_3D_SIZE 2\nBOGUS 0 0")
        }
    }

    @Test fun acceptsUtf8BomBeforeTheFirstDirective() {
        assertEquals(2, CubeLut.parse("\uFEFF${identityCube()}").size)
    }

    private fun identityCube() = """
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
    """.trimIndent()
}
