package io.github.dearzl.mirrorbridge

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class UsbPtpCodecTest {
    @Test fun sessionCommandContainsLengthTypeCodeTransactionAndParameter() {
        assertArrayEquals(
            byteArrayOf(
                16, 0, 0, 0,
                1, 0,
                2, 16,
                7, 0, 0, 0,
                1, 0, 0, 0,
            ),
            UsbPtpCodec.command(0x1002, 7, intArrayOf(1)),
        )
    }

    @Test fun headerUsesUnsignedLengthAndPreservesTransaction() {
        val parsed = UsbPtpCodec.parseHeader(
            byteArrayOf(
                20, 0, 0, 0,
                3, 0,
                1, 32,
                -1, -1, -1, 127,
            ),
        )
        assertEquals(20, parsed.length)
        assertEquals(UsbPtpCodec.RESPONSE, parsed.type)
        assertEquals(0x2001, parsed.code)
        assertEquals(Int.MAX_VALUE, parsed.transaction)
    }

    @Test fun dataHeaderUsesOperationTransactionAndPayloadLength() {
        assertArrayEquals(
            byteArrayOf(
                17, 0, 0, 0,
                2, 0,
                22, 16,
                9, 0, 0, 0,
            ),
            UsbPtpCodec.dataHeader(0x1016, 9, 5),
        )
    }

    @Test fun malformedHeadersAndExcessParametersAreRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            UsbPtpCodec.parseHeader(ByteArray(11))
        }
        assertThrows(IllegalArgumentException::class.java) {
            UsbPtpCodec.parseHeader(ByteArray(12))
        }
        assertThrows(IllegalArgumentException::class.java) {
            UsbPtpCodec.command(0x1001, 1, IntArray(6))
        }
    }
}
