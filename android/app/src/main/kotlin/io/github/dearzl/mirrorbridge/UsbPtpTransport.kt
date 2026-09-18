package io.github.dearzl.mirrorbridge

import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbRequest
import java.io.Closeable
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class PtpResponseException(val operation: Int, val response: Int) :
    IllegalStateException("PTP response 0x${response.toString(16)} for operation 0x${operation.toString(16)}")

internal data class UsbPtpContainer(
    val length: Long,
    val type: Int,
    val code: Int,
    val transaction: Int,
)

internal object UsbPtpCodec {
    const val COMMAND = 1
    const val DATA = 2
    const val RESPONSE = 3
    const val EVENT = 4
    const val HEADER_SIZE = 12

    fun command(code: Int, transaction: Int, params: IntArray): ByteArray {
        require(params.size <= 5) { "PTP supports at most five operation parameters" }
        return ByteBuffer.allocate(HEADER_SIZE + params.size * 4).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(capacity())
            putShort(COMMAND.toShort())
            putShort(code.toShort())
            putInt(transaction)
            params.forEach(::putInt)
        }.array()
    }

    fun dataHeader(code: Int, transaction: Int, bytes: Int): ByteArray =
        ByteBuffer.allocate(HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(HEADER_SIZE + bytes)
            putShort(DATA.toShort())
            putShort(code.toShort())
            putInt(transaction)
        }.array()

    fun parseHeader(bytes: ByteArray): UsbPtpContainer {
        require(bytes.size == HEADER_SIZE) { "PTP container header is incomplete" }
        val data = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val length = data.int.toLong() and 0xffffffffL
        val type = data.short.toInt() and 0xffff
        val code = data.short.toInt() and 0xffff
        val transaction = data.int
        require(length >= HEADER_SIZE) { "PTP container length is invalid" }
        require(type in COMMAND..EVENT) { "PTP container type is invalid" }
        return UsbPtpContainer(length, type, code, transaction)
    }
}

class UsbPtpTransport(
    private val device: UsbDevice,
    private val connection: UsbDeviceConnection,
    private val onEvent: (Int, IntArray) -> Unit,
) : Closeable {
    private val closed = AtomicBoolean(false)
    private val cancelled = AtomicBoolean(false)
    private val trace = ArrayDeque<String>()
    private val ptpInterface: UsbInterface
    private val input: UsbEndpoint
    private val output: UsbEndpoint
    private val interrupt: UsbEndpoint?
    private var transaction = 0
    private var eventThread: Thread? = null
    @Volatile private var eventRequest: UsbRequest? = null
    private val receiveBuffer = ByteArray(16 * 1024)
    private var receivePosition = 0
    private var receiveLimit = 0

    init {
        ptpInterface = (0 until device.interfaceCount).map(device::getInterface).firstOrNull {
            it.interfaceClass == UsbConstants.USB_CLASS_STILL_IMAGE
        } ?: error("USB device has no still-image interface")
        val endpoints = (0 until ptpInterface.endpointCount).map(ptpInterface::getEndpoint)
        input = endpoints.firstOrNull {
            it.type == UsbConstants.USB_ENDPOINT_XFER_BULK && it.direction == UsbConstants.USB_DIR_IN
        } ?: error("PTP bulk input endpoint is missing")
        output = endpoints.firstOrNull {
            it.type == UsbConstants.USB_ENDPOINT_XFER_BULK && it.direction == UsbConstants.USB_DIR_OUT
        } ?: error("PTP bulk output endpoint is missing")
        interrupt = endpoints.firstOrNull {
            it.type == UsbConstants.USB_ENDPOINT_XFER_INT && it.direction == UsbConstants.USB_DIR_IN
        }
        check(connection.claimInterface(ptpInterface, true)) { "Could not claim the PTP USB interface" }
    }

    @Synchronized
    fun open(): Boolean {
        check(!closed.get()) { "USB transport is closed" }
        var response = commandResponse(0x1002, intArrayOf(1), 15_000)
        if (response == 0x201e) {
            commandResponse(0x1003, intArrayOf(), 5_000)
            response = commandResponse(0x1002, intArrayOf(1), 15_000)
        }
        if (response != 0x2001) throw PtpResponseException(0x1002, response)
        startEvents()
        return true
    }

    @Synchronized
    fun data(code: Int, params: IntArray, timeout: Int = 15_000): ByteArray {
        val transaction = begin(code, params, timeout)
        val header = readHeader(input, timeout)
        validateTransaction(header, transaction)
        if (header.type == UsbPtpCodec.RESPONSE) {
            skipPayload(input, header.length - UsbPtpCodec.HEADER_SIZE, timeout)
            if (header.code != 0x2001) throw PtpResponseException(code, header.code)
            error("PTP operation 0x${code.toString(16)} returned no data")
        }
        check(header.type == UsbPtpCodec.DATA && header.code == code) { "PTP data container does not match its operation" }
        val count = header.length - UsbPtpCodec.HEADER_SIZE
        require(count <= 64L * 1024 * 1024 && count <= Int.MAX_VALUE) { "PTP data response is too large for memory" }
        val bytes = ByteArray(count.toInt())
        readExact(input, bytes, 0, bytes.size, timeout)
        finish(code, transaction, timeout)
        log("DATA op=0x${code.toString(16)} tx=$transaction bytes=${bytes.size}")
        return bytes
    }

    @Synchronized
    fun command(code: Int, params: IntArray, timeout: Int = 15_000): Int = commandResponse(code, params, timeout)

    @Synchronized
    fun writeProperty(property: Int, bytes: ByteArray, timeout: Int = 15_000) {
        val operation = 0x1016
        val tx = begin(operation, intArrayOf(property), timeout)
        writeExact(output, UsbPtpCodec.dataHeader(operation, tx, bytes.size) + bytes, timeout)
        finish(operation, tx, timeout)
        log("WRITE property=0x${property.toString(16)} tx=$tx bytes=${bytes.size}")
    }

    @Synchronized
    fun download(
        operation: Int,
        params: IntArray,
        destination: OutputStream,
        timeout: Int = 15_000,
        progress: (Long) -> Unit,
    ): Long {
        cancelled.set(false)
        val tx = begin(operation, params, timeout)
        val header = readHeader(input, timeout)
        validateTransaction(header, tx)
        if (header.type == UsbPtpCodec.RESPONSE) {
            skipPayload(input, header.length - UsbPtpCodec.HEADER_SIZE, timeout)
            if (header.code != 0x2001) throw PtpResponseException(operation, header.code)
            error("PTP download returned no data")
        }
        check(header.type == UsbPtpCodec.DATA && header.code == operation) { "PTP download data header is invalid" }
        var remaining = header.length - UsbPtpCodec.HEADER_SIZE
        var received = 0L
        val buffer = ByteArray(256 * 1024)
        while (remaining > 0) {
            check(!cancelled.get()) { "Transfer cancelled" }
            val count = minOf(buffer.size.toLong(), remaining).toInt()
            readExact(input, buffer, 0, count, timeout)
            destination.write(buffer, 0, count)
            received += count
            remaining -= count
            progress(received)
        }
        finish(operation, tx, timeout)
        log("DOWNLOAD op=0x${operation.toString(16)} tx=$tx bytes=$received")
        return received
    }

    fun cancel() {
        cancelled.set(true)
        // A partially read data phase cannot be reused as a fresh transaction.
        // Closing also interrupts a blocking USB read; callers reconnect explicitly.
        close()
    }

    @Synchronized
    fun traceText(): String = trace.joinToString("\n")

    private fun nextTransaction(): Int {
        transaction = if (transaction == Int.MAX_VALUE) 1 else transaction + 1
        return transaction
    }

    private fun begin(code: Int, params: IntArray, timeout: Int): Int {
        check(!closed.get()) { "USB transport is closed" }
        val tx = nextTransaction()
        writeExact(output, UsbPtpCodec.command(code, tx, params), timeout)
        log("COMMAND op=0x${code.toString(16)} tx=$tx params=${params.toList()}")
        return tx
    }

    private fun commandResponse(code: Int, params: IntArray, timeout: Int): Int {
        val tx = begin(code, params, timeout)
        val response = readHeader(input, timeout)
        validateTransaction(response, tx)
        check(response.type == UsbPtpCodec.RESPONSE) { "PTP command returned an unexpected data phase" }
        skipPayload(input, response.length - UsbPtpCodec.HEADER_SIZE, timeout)
        log("RESPONSE op=0x${code.toString(16)} tx=$tx code=0x${response.code.toString(16)}")
        return response.code
    }

    private fun finish(operation: Int, tx: Int, timeout: Int) {
        val response = readHeader(input, timeout)
        validateTransaction(response, tx)
        check(response.type == UsbPtpCodec.RESPONSE) { "PTP operation response container is invalid" }
        skipPayload(input, response.length - UsbPtpCodec.HEADER_SIZE, timeout)
        if (response.code != 0x2001) throw PtpResponseException(operation, response.code)
    }

    private fun validateTransaction(container: UsbPtpContainer, expected: Int) {
        check(container.transaction == expected) {
            "PTP transaction mismatch: expected $expected, received ${container.transaction}"
        }
    }

    private fun readHeader(endpoint: UsbEndpoint, timeout: Int): UsbPtpContainer {
        val bytes = ByteArray(UsbPtpCodec.HEADER_SIZE)
        readExact(endpoint, bytes, 0, bytes.size, timeout)
        return UsbPtpCodec.parseHeader(bytes)
    }

    private fun readExact(endpoint: UsbEndpoint, target: ByteArray, offset: Int, count: Int, timeout: Int) {
        check(endpoint == input) { "Interrupt events require UsbRequest" }
        var position = offset
        val end = offset + count
        while (position < end) {
            check(!closed.get()) { "USB connection closed; reconnect the camera" }
            if (receivePosition == receiveLimit) {
                // Always receive whole USB packets, retaining any bytes beyond
                // this PTP header/body request for the next parser read.
                val read = connection.bulkTransfer(endpoint, receiveBuffer, 0, receiveBuffer.size, timeout)
                if (read < 0) {
                    close()
                    error("USB read timed out or disconnected; reconnect the camera")
                }
                if (read == 0) continue // USB zero-length packet at a transfer boundary.
                receivePosition = 0
                receiveLimit = read
            }
            val available = minOf(end - position, receiveLimit - receivePosition)
            receiveBuffer.copyInto(target, position, receivePosition, receivePosition + available)
            receivePosition += available
            position += available
        }
    }

    private fun writeExact(endpoint: UsbEndpoint, bytes: ByteArray, timeout: Int) {
        var offset = 0
        while (offset < bytes.size) {
            val written = connection.bulkTransfer(endpoint, bytes, offset, bytes.size - offset, timeout)
            check(written > 0) { if (closed.get()) "USB transport is closed" else "USB write timed out or disconnected" }
            offset += written
        }
    }

    private fun skipPayload(endpoint: UsbEndpoint, count: Long, timeout: Int) {
        require(count <= 20) { "PTP response contains too many parameters" }
        if (count > 0) readExact(endpoint, ByteArray(count.toInt()), 0, count.toInt(), timeout)
    }

    private fun startEvents() {
        val endpoint = interrupt ?: return
        eventThread = thread(name = "MirrorBridge-PTP-events", isDaemon = true) {
            val request = UsbRequest()
            try {
                check(request.initialize(connection, endpoint)) { "Could not initialize USB event request" }
                eventRequest = request
                val buffer = ByteBuffer.allocateDirect(maxOf(32, endpoint.maxPacketSize))
                var pending = byteArrayOf()
                while (!closed.get()) {
                    buffer.clear()
                    check(request.queue(buffer)) { "Could not queue USB event request" }
                    check(connection.requestWait() === request) { "USB event request interrupted" }
                    buffer.flip()
                    val incoming = ByteArray(buffer.remaining())
                    buffer.get(incoming)
                    pending += incoming
                    while (pending.size >= UsbPtpCodec.HEADER_SIZE) {
                        val header = UsbPtpCodec.parseHeader(pending.copyOfRange(0, UsbPtpCodec.HEADER_SIZE))
                        check(header.type == UsbPtpCodec.EVENT && header.length <= 32 && header.length % 4L == 0L) {
                            "Invalid USB event container"
                        }
                        if (pending.size < header.length) break
                        val data = ByteBuffer.wrap(pending).order(ByteOrder.LITTLE_ENDIAN)
                        data.position(UsbPtpCodec.HEADER_SIZE)
                        val params = IntArray((header.length.toInt() - UsbPtpCodec.HEADER_SIZE) / 4) { data.int }
                        onEvent(header.code, params)
                        pending = pending.copyOfRange(header.length.toInt(), pending.size)
                    }
                }
            } catch (error: Throwable) {
                if (!closed.get()) log("EVENT stopped; polling remains available: ${error.message}")
            } finally {
                eventRequest = null
                runCatching { request.cancel() }
                request.close()
            }
        }
    }

    @Synchronized
    private fun log(message: String) {
        if (trace.size >= 500) trace.removeFirst()
        trace.addLast("${java.time.Instant.now()} $message")
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        cancelled.set(true)
        runCatching { eventRequest?.cancel() }
        runCatching { connection.releaseInterface(ptpInterface) }
        runCatching { connection.close() }
        eventThread?.interrupt()
        eventThread = null
    }
}
