package io.github.dearzl.mirrorbridge

import android.hardware.usb.*
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.annotation.RealObject
import org.robolectric.util.ReflectionHelpers
import org.robolectric.util.ReflectionHelpers.ClassParameter
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], shadows = [UsbPtpTransportTest.DeviceShadow::class, UsbPtpTransportTest.ConnectionShadow::class, UsbPtpTransportTest.RequestShadow::class])
class UsbPtpTransportTest {
    @Implements(UsbDevice::class)
    class DeviceShadow {
        @Implementation fun getInterfaceCount() = 1
        @Implementation fun getInterface(index: Int): UsbInterface = usbInterface
    }

    @Implements(UsbDeviceConnection::class)
    class ConnectionShadow {
        @Implementation fun claimInterface(intf: UsbInterface, force: Boolean) = true
        @Implementation fun releaseInterface(intf: UsbInterface) = true
        @Implementation fun close() { closes++ }
        @Implementation fun requestWait(): UsbRequest? = queuedRequest
        @Implementation fun bulkTransfer(endpoint: UsbEndpoint, bytes: ByteArray, offset: Int, length: Int, timeout: Int): Int {
            if (endpoint.direction == UsbConstants.USB_DIR_OUT) return length
            if (packets.isEmpty()) return -1
            val packet = packets.removeFirst()
            // A USB packet larger than the host buffer overflows; it is not a stream read.
            if (length < packet.size) return -1
            packet.copyInto(bytes, offset)
            return packet.size
        }
    }

    @Implements(UsbRequest::class)
    class RequestShadow {
        @RealObject lateinit var self: UsbRequest
        @Implementation fun initialize(connection: UsbDeviceConnection, endpoint: UsbEndpoint): Boolean {
            assertEquals(UsbConstants.USB_ENDPOINT_XFER_INT, endpoint.type)
            return true
        }
        @Implementation fun queue(buffer: ByteBuffer): Boolean {
            if (eventPackets.isEmpty()) return false
            queuedRequest = self
            buffer.put(eventPackets.removeFirst())
            return true
        }
        @Implementation fun cancel() = true
        @Implementation fun close() {}
    }

    companion object {
        lateinit var usbInterface: UsbInterface
        val packets = ArrayDeque<ByteArray>()
        var closes = 0
        val eventPackets = ArrayDeque<ByteArray>()
        var queuedRequest: UsbRequest? = null
        fun packet(type: Int, code: Int, tx: Int, payload: ByteArray = byteArrayOf()): ByteArray =
            ByteBuffer.allocate(12 + payload.size).order(ByteOrder.LITTLE_ENDIAN).apply {
                putInt(capacity()); putShort(type.toShort()); putShort(code.toShort()); putInt(tx); put(payload)
            }.array()
    }

    @Before fun setup() {
        packets.clear(); eventPackets.clear(); closes = 0; queuedRequest = null
        fun endpoint(address: Int) = ReflectionHelpers.callConstructor(UsbEndpoint::class.java,
            ClassParameter.from(Int::class.javaPrimitiveType, address),
            ClassParameter.from(Int::class.javaPrimitiveType, 2),
            ClassParameter.from(Int::class.javaPrimitiveType, 512),
            ClassParameter.from(Int::class.javaPrimitiveType, 0))
        usbInterface = ReflectionHelpers.callConstructor(UsbInterface::class.java,
            ClassParameter.from(Int::class.javaPrimitiveType, 0),
            ClassParameter.from(Int::class.javaPrimitiveType, 0),
            ClassParameter.from(String::class.java, "PTP"),
            ClassParameter.from(Int::class.javaPrimitiveType, 6),
            ClassParameter.from(Int::class.javaPrimitiveType, 1),
            ClassParameter.from(Int::class.javaPrimitiveType, 1))
        ReflectionHelpers.setField(usbInterface, "mEndpoints", arrayOf(endpoint(0x81), endpoint(0x02)))
    }

    private fun transport() = UsbPtpTransport(
        ReflectionHelpers.newInstance(UsbDevice::class.java),
        ReflectionHelpers.newInstance(UsbDeviceConnection::class.java),
        { _, _ -> },
    )

    @Test fun combinedHeaderAndBodySurvivePacketReads() {
        val body = ByteArray(1300) { (it % 251).toByte() }
        val data = packet(2, 0x1001, 1, body)
        packets.add(data.copyOfRange(0, 512))
        packets.add(data.copyOfRange(512, 1024))
        packets.add(data.copyOfRange(1024, data.size))
        packets.add(packet(3, 0x2001, 1))
        transport().use { assertArrayEquals(body, it.data(0x1001, intArrayOf())) }
        assertTrue(packets.isEmpty())
    }

    @Test fun errorParametersAreConsumedBeforeNextTransaction() {
        packets.add(packet(3, 0x2019, 1, byteArrayOf(7, 0, 0, 0)))
        packets.add(packet(2, 0x1001, 2, byteArrayOf(42)))
        packets.add(packet(3, 0x2001, 2))
        transport().use {
            val failure = assertThrows(PtpResponseException::class.java) { it.data(0x1001, intArrayOf()) }
            assertEquals(0x2019, failure.response)
            assertArrayEquals(byteArrayOf(42), it.data(0x1001, intArrayOf()))
        }
    }

    @Test fun cancellationClosesConnectionAndRejectsReuse() {
        transport().use {
            it.cancel()
            assertEquals(1, closes)
            assertThrows(IllegalStateException::class.java) { it.command(0x1004, intArrayOf()) }
        }
        assertEquals(1, closes)
    }

    @Test fun zeroLengthBoundaryAndSplitHeaderDoNotLoseBytes() {
        val frame = packet(2, 0x1001, 1, byteArrayOf(11, 12))
        packets.add(byteArrayOf())
        packets.add(frame.copyOfRange(0, 8))
        packets.add(frame.copyOfRange(8, frame.size))
        packets.add(byteArrayOf())
        packets.add(packet(3, 0x2001, 1))
        transport().use { assertArrayEquals(byteArrayOf(11, 12), it.data(0x1001, intArrayOf())) }
    }

    @Test fun interruptEventsUseRequestsAndPreserveFragmentedContainers() {
        val interrupt = ReflectionHelpers.callConstructor(UsbEndpoint::class.java,
            ClassParameter.from(Int::class.javaPrimitiveType, 0x83),
            ClassParameter.from(Int::class.javaPrimitiveType, 3),
            ClassParameter.from(Int::class.javaPrimitiveType, 64),
            ClassParameter.from(Int::class.javaPrimitiveType, 1))
        ReflectionHelpers.setField(usbInterface, "mEndpoints",
            arrayOf(usbInterface.getEndpoint(0), usbInterface.getEndpoint(1), interrupt))
        packets.add(packet(3, 0x2001, 1))
        val events = packet(4, 0x4002, 0, byteArrayOf(7, 0, 0, 0)) + packet(4, 0x400a, 0)
        eventPackets.add(events.copyOfRange(0, 8))
        eventPackets.add(events.copyOfRange(8, events.size))
        val ready = CountDownLatch(2)
        val seen = mutableListOf<Pair<Int, List<Int>>>()
        UsbPtpTransport(ReflectionHelpers.newInstance(UsbDevice::class.java),
            ReflectionHelpers.newInstance(UsbDeviceConnection::class.java),
            { code, params -> seen.add(code to params.toList()); ready.countDown() }).use {
            assertTrue(it.open())
            assertTrue("Expected both interrupt events", ready.await(3, TimeUnit.SECONDS))
            assertEquals(listOf(0x4002 to listOf(7), 0x400a to emptyList<Int>()), seen)
        }
    }
}
