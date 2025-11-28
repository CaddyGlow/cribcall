package com.cribcall.cribcall

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Codec for the control message wire format.
 * Format: 4-byte big-endian length prefix + UTF-8 JSON payload.
 * Compatible with Dart ControlFrameCodec.
 */
object ControlMessageCodec {
    const val MAX_FRAME_LENGTH = 512_000
    const val HEADER_SIZE = 4

    /**
     * Encode a JSON string into a length-prefixed frame.
     */
    fun encodeFrame(json: String): ByteArray {
        val payload = json.toByteArray(Charsets.UTF_8)
        val frame = ByteArray(HEADER_SIZE + payload.size)

        // Write 4-byte big-endian length
        frame[0] = (payload.size shr 24).toByte()
        frame[1] = (payload.size shr 16).toByte()
        frame[2] = (payload.size shr 8).toByte()
        frame[3] = payload.size.toByte()

        // Copy payload
        System.arraycopy(payload, 0, frame, HEADER_SIZE, payload.size)

        return frame
    }

    /**
     * Stateful decoder for streaming length-prefixed frames.
     */
    class FrameDecoder(private val maxFrameLength: Int = MAX_FRAME_LENGTH) {
        private val buffer = mutableListOf<Byte>()

        /**
         * Add a chunk of data and return any complete messages.
         */
        fun addChunk(chunk: ByteArray): List<String> {
            buffer.addAll(chunk.toList())
            val messages = mutableListOf<String>()

            while (buffer.size >= HEADER_SIZE) {
                // Read length prefix
                val lengthBytes = ByteArray(HEADER_SIZE)
                for (i in 0 until HEADER_SIZE) {
                    lengthBytes[i] = buffer[i]
                }
                val length = ByteBuffer.wrap(lengthBytes).order(ByteOrder.BIG_ENDIAN).int

                if (length < 0 || length > maxFrameLength) {
                    throw IllegalArgumentException("Frame length $length exceeds maximum $maxFrameLength")
                }

                if (buffer.size < HEADER_SIZE + length) {
                    // Not enough data yet
                    break
                }

                // Extract payload
                val payload = ByteArray(length)
                for (i in 0 until length) {
                    payload[i] = buffer[HEADER_SIZE + i]
                }

                // Remove consumed bytes
                repeat(HEADER_SIZE + length) {
                    buffer.removeAt(0)
                }

                // Decode as UTF-8 string
                messages.add(String(payload, Charsets.UTF_8))
            }

            return messages
        }

        /**
         * Clear the buffer.
         */
        fun reset() {
            buffer.clear()
        }
    }
}
