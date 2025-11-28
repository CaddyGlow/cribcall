package com.cribcall.cribcall

import java.io.OutputStream

/**
 * Utility for writing HTTP responses over SSL sockets.
 */
object HttpResponseWriter {

    /**
     * Send an HTTP response with optional JSON body.
     */
    fun sendResponse(output: OutputStream, statusCode: Int, body: String?) {
        val statusText = getStatusText(statusCode)
        val bodyBytes = body?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)

        val response = StringBuilder()
        response.append("HTTP/1.1 $statusCode $statusText\r\n")
        response.append("Content-Type: application/json\r\n")
        response.append("Content-Length: ${bodyBytes.size}\r\n")
        response.append("Cache-Control: no-store\r\n")
        response.append("Connection: close\r\n")
        response.append("\r\n")

        output.write(response.toString().toByteArray(Charsets.UTF_8))
        if (bodyBytes.isNotEmpty()) {
            output.write(bodyBytes)
        }
        output.flush()
    }

    /**
     * Send an HTTP error response with a JSON error message.
     */
    fun sendError(output: OutputStream, statusCode: Int, message: String) {
        sendResponse(output, statusCode, """{"error":"$message"}""")
    }

    /**
     * Get the status text for an HTTP status code.
     */
    private fun getStatusText(statusCode: Int): String {
        return when (statusCode) {
            200 -> "OK"
            400 -> "Bad Request"
            401 -> "Unauthorized"
            403 -> "Forbidden"
            404 -> "Not Found"
            500 -> "Internal Server Error"
            503 -> "Service Unavailable"
            else -> "Unknown"
        }
    }
}
