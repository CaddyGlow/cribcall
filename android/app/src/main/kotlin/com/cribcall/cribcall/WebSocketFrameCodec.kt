package com.cribcall.cribcall

import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer

/**
 * Codec for WebSocket frame encoding and decoding.
 * Handles the low-level WebSocket protocol framing.
 */
object WebSocketFrameCodec {
    const val OPCODE_TEXT = 0x1
    const val OPCODE_BINARY = 0x2
    const val OPCODE_CLOSE = 0x8
    const val OPCODE_PING = 0x9
    const val OPCODE_PONG = 0xA

    private const val MAX_PAYLOAD_SIZE = 10_000_000

    /**
     * Represents a decoded WebSocket frame.
     */
    data class Frame(
        val fin: Boolean,
        val opcode: Int,
        val payload: ByteArray
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (javaClass != other?.javaClass) return false
            other as Frame
            return fin == other.fin && opcode == other.opcode && payload.contentEquals(other.payload)
        }

        override fun hashCode(): Int {
            var result = fin.hashCode()
            result = 31 * result + opcode
            result = 31 * result + payload.contentHashCode()
            return result
        }
    }

    /**
     * Read a WebSocket frame from the input stream.
     * Returns null if the stream ends or an error occurs.
     */
    fun readFrame(input: InputStream): Frame? {
        val b1 = input.read()
        if (b1 < 0) return null
        val b2 = input.read()
        if (b2 < 0) return null

        val fin = (b1 and 0x80) != 0
        val opcode = b1 and 0x0F
        val masked = (b2 and 0x80) != 0
        var payloadLen = (b2 and 0x7F).toLong()

        // Extended payload length
        if (payloadLen == 126L) {
            val lenBytes = ByteArray(2)
            if (input.read(lenBytes) != 2) return null
            payloadLen = (((lenBytes[0].toInt() and 0xFF) shl 8) or
                (lenBytes[1].toInt() and 0xFF)).toLong()
        } else if (payloadLen == 127L) {
            val lenBytes = ByteArray(8)
            if (input.read(lenBytes) != 8) return null
            payloadLen = ByteBuffer.wrap(lenBytes).getLong()
        }

        // Masking key (if present)
        val maskKey = if (masked) {
            val key = ByteArray(4)
            if (input.read(key) != 4) return null
            key
        } else null

        // Payload size check
        if (payloadLen > MAX_PAYLOAD_SIZE) {
            return null
        }

        // Read payload
        val payload = ByteArray(payloadLen.toInt())
        var read = 0
        while (read < payloadLen) {
            val n = input.read(payload, read, (payloadLen - read).toInt())
            if (n < 0) return null
            read += n
        }

        // Unmask if needed
        if (maskKey != null) {
            for (i in payload.indices) {
                payload[i] = (payload[i].toInt() xor maskKey[i % 4].toInt()).toByte()
            }
        }

        return Frame(fin, opcode, payload)
    }

    /**
     * Write a binary WebSocket frame to the output stream.
     * Server-to-client frames are not masked per RFC 6455.
     */
    fun writeBinaryFrame(output: OutputStream, payload: ByteArray) {
        val header = buildFrameHeader(OPCODE_BINARY, payload.size)
        output.write(header)
        output.write(payload)
        output.flush()
    }

    /**
     * Write a pong frame in response to a ping.
     */
    fun writePongFrame(output: OutputStream, payload: ByteArray) {
        val header = byteArrayOf(
            (0x80 or OPCODE_PONG).toByte(),
            payload.size.toByte()
        )
        output.write(header)
        output.write(payload)
        output.flush()
    }

    /**
     * Write a close frame.
     */
    fun writeCloseFrame(output: OutputStream) {
        val closeFrame = byteArrayOf(
            (0x80 or OPCODE_CLOSE).toByte(),
            0.toByte()
        )
        output.write(closeFrame)
        output.flush()
    }

    /**
     * Build the frame header for a given opcode and payload size.
     */
    private fun buildFrameHeader(opcode: Int, payloadSize: Int): ByteArray {
        return when {
            payloadSize < 126 -> byteArrayOf(
                (0x80 or opcode).toByte(),
                payloadSize.toByte()
            )
            payloadSize <= 65535 -> byteArrayOf(
                (0x80 or opcode).toByte(),
                126.toByte(),
                (payloadSize shr 8).toByte(),
                payloadSize.toByte()
            )
            else -> {
                val header = ByteArray(10)
                header[0] = (0x80 or opcode).toByte()
                header[1] = 127.toByte()
                val len = payloadSize.toLong()
                for (i in 0..7) {
                    header[2 + i] = (len shr (56 - i * 8)).toByte()
                }
                header
            }
        }
    }
}
