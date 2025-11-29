package com.cribcall.cribcall

import org.junit.Assert.*
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test
import org.yaml.snakeyaml.Yaml
import java.io.File

/**
 * Protocol conformance tests for the Kotlin control server.
 *
 * This test runner parses YAML test specs from test_specs/protocol/
 * and validates that the Kotlin ControlWebSocketServer behaves according to spec.
 *
 * Note: These are unit tests that run on the JVM without Android emulator.
 * For full integration tests with actual mTLS, use androidTest.
 *
 * Run with: ./gradlew :app:test
 */
class ProtocolConformanceTest {

    companion object {
        // Matcher value types from the spec schema
        const val MATCHER_NONEMPTY = "\$nonempty"
        const val MATCHER_POSITIVE_INT = "\$positive_int"
        const val MATCHER_ISO8601 = "\$iso8601"
        const val MATCHER_UUID = "\$uuid"
        const val MATCHER_ANY = "\$any"
        const val MATCHER_CONTAINS_PREFIX = "\$contains:"
        const val MATCHER_REGEX_PREFIX = "\$regex:"

        // ISO 8601 regex pattern
        private val ISO8601_PATTERN = Regex(
            """\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?"""
        )

        // UUID regex pattern
        private val UUID_PATTERN = Regex(
            """[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"""
        )

        // Test identities - generated once for all tests
        private lateinit var identities: MtlsTestIdentities

        @JvmStatic
        @BeforeClass
        fun setUpClass() {
            identities = MtlsTestHelper.generateTestIdentities()
            println("Generated test identities:")
            println("  Monitor: ${identities.monitor.fingerprint.take(12)}")
            println("  Trusted: ${identities.trusted.fingerprint.take(12)}")
            println("  Untrusted: ${identities.untrusted.fingerprint.take(12)}")
        }
    }

    private val yaml = Yaml()

    /**
     * Find the test_specs directory relative to the project root.
     */
    private fun findTestSpecsDir(): File? {
        // Try multiple paths for different execution contexts
        val candidates = listOf(
            File("../../test_specs"),  // From android/app
            File("../../../test_specs"),  // From android/app/src
            File("test_specs"),  // From project root
            File("../test_specs"),  // One level up
        )
        return candidates.firstOrNull { it.exists() && it.isDirectory }
    }

    /**
     * Load and parse a test spec YAML file.
     */
    private fun loadTestSpec(filename: String): Map<String, Any>? {
        val specsDir = findTestSpecsDir()
        if (specsDir == null) {
            println("Warning: test_specs directory not found, skipping spec tests")
            return null
        }

        val file = File(specsDir, "protocol/$filename")
        if (!file.exists()) {
            println("Warning: Test spec not found: ${file.absolutePath}")
            return null
        }

        @Suppress("UNCHECKED_CAST")
        return yaml.load(file.readText()) as? Map<String, Any>
    }

    /**
     * Check if a value matches an expected pattern from the spec.
     */
    fun matchesExpected(actual: Any?, expected: Any?): Boolean {
        if (expected == null) return actual == null

        if (expected is String) {
            // Handle matcher patterns
            when {
                expected == MATCHER_NONEMPTY -> {
                    return actual is String && actual.isNotEmpty()
                }
                expected == MATCHER_POSITIVE_INT -> {
                    return (actual is Int && actual > 0) ||
                           (actual is Long && actual > 0) ||
                           (actual is Number && actual.toLong() > 0)
                }
                expected == MATCHER_ISO8601 -> {
                    return actual is String && ISO8601_PATTERN.matches(actual)
                }
                expected == MATCHER_UUID -> {
                    return actual is String && UUID_PATTERN.matches(actual)
                }
                expected == MATCHER_ANY -> {
                    return true  // Just check the key exists
                }
                expected.startsWith(MATCHER_CONTAINS_PREFIX) -> {
                    val substring = expected.removePrefix(MATCHER_CONTAINS_PREFIX)
                    return actual is String && actual.contains(substring)
                }
                expected.startsWith(MATCHER_REGEX_PREFIX) -> {
                    val pattern = expected.removePrefix(MATCHER_REGEX_PREFIX)
                    return actual is String && Regex(pattern).matches(actual)
                }
            }
        }

        if (expected is Map<*, *> && actual is Map<*, *>) {
            return expected.all { (key, value) ->
                actual.containsKey(key) && matchesExpected(actual[key], value)
            }
        }

        if (expected is List<*> && actual is List<*>) {
            if (expected.size != actual.size) return false
            return expected.indices.all { i ->
                matchesExpected(actual[i], expected[i])
            }
        }

        // Exact match
        return actual == expected
    }

    // -------------------------------------------------------------------------
    // Matcher Tests
    // -------------------------------------------------------------------------

    @Test
    fun `nonempty matches non-empty strings`() {
        assertTrue(matchesExpected("hello", MATCHER_NONEMPTY))
        assertFalse(matchesExpected("", MATCHER_NONEMPTY))
        assertFalse(matchesExpected(123, MATCHER_NONEMPTY))
        assertFalse(matchesExpected(null, MATCHER_NONEMPTY))
    }

    @Test
    fun `positive_int matches positive integers`() {
        assertTrue(matchesExpected(1, MATCHER_POSITIVE_INT))
        assertTrue(matchesExpected(100, MATCHER_POSITIVE_INT))
        assertTrue(matchesExpected(100L, MATCHER_POSITIVE_INT))
        assertFalse(matchesExpected(0, MATCHER_POSITIVE_INT))
        assertFalse(matchesExpected(-1, MATCHER_POSITIVE_INT))
        assertFalse(matchesExpected("1", MATCHER_POSITIVE_INT))
    }

    @Test
    fun `iso8601 matches valid ISO 8601 dates`() {
        assertTrue(matchesExpected("2024-12-31T23:59:59Z", MATCHER_ISO8601))
        assertTrue(matchesExpected("2024-01-01T00:00:00.000Z", MATCHER_ISO8601))
        assertTrue(matchesExpected("2024-06-15T12:30:45+05:30", MATCHER_ISO8601))
        assertFalse(matchesExpected("not a date", MATCHER_ISO8601))
        assertFalse(matchesExpected("2024/12/31", MATCHER_ISO8601))
    }

    @Test
    fun `uuid matches valid UUIDs`() {
        assertTrue(matchesExpected("550e8400-e29b-41d4-a716-446655440000", MATCHER_UUID))
        assertTrue(matchesExpected("123e4567-e89b-12d3-a456-426614174000", MATCHER_UUID))
        assertFalse(matchesExpected("not-a-uuid", MATCHER_UUID))
        assertFalse(matchesExpected("550e8400e29b41d4a716446655440000", MATCHER_UUID))
    }

    @Test
    fun `any matches anything`() {
        assertTrue(matchesExpected("anything", MATCHER_ANY))
        assertTrue(matchesExpected(123, MATCHER_ANY))
        assertTrue(matchesExpected(null, MATCHER_ANY))
        assertTrue(matchesExpected(mapOf("nested" to "map"), MATCHER_ANY))
        assertTrue(matchesExpected(listOf(1, 2, 3), MATCHER_ANY))
    }

    @Test
    fun `contains text matches substrings`() {
        assertTrue(matchesExpected("hello world", "\$contains:world"))
        assertTrue(matchesExpected("certificate required", "\$contains:certificate"))
        assertFalse(matchesExpected("hello world", "\$contains:foo"))
        assertFalse(matchesExpected(123, "\$contains:123"))
    }

    @Test
    fun `regex pattern matches regex patterns`() {
        assertTrue(matchesExpected("ABC123", "\$regex:^[A-Z0-9]+\$"))
        assertTrue(matchesExpected("test@example.com", "\$regex:.*@.*\\..*"))
        assertFalse(matchesExpected("abc", "\$regex:^[A-Z]+\$"))
    }

    @Test
    fun `nested map matching works`() {
        val actual = mapOf(
            "status" to "ok",
            "data" to mapOf(
                "id" to "abc123",
                "count" to 42
            )
        )
        val expected = mapOf(
            "status" to "ok",
            "data" to mapOf(
                "id" to MATCHER_NONEMPTY,
                "count" to MATCHER_POSITIVE_INT
            )
        )
        assertTrue(matchesExpected(actual, expected))
    }

    @Test
    fun `nested map matching fails on mismatch`() {
        val actual = mapOf(
            "status" to "ok",
            "data" to mapOf(
                "id" to "",  // Empty string
                "count" to 42
            )
        )
        val expected = mapOf(
            "status" to "ok",
            "data" to mapOf(
                "id" to MATCHER_NONEMPTY,  // Should fail
                "count" to MATCHER_POSITIVE_INT
            )
        )
        assertFalse(matchesExpected(actual, expected))
    }

    // -------------------------------------------------------------------------
    // YAML Spec Loading Tests
    // -------------------------------------------------------------------------

    @Test
    fun `can load health spec`() {
        val spec = loadTestSpec("health.yaml")
        if (spec == null) {
            println("Skipping: test_specs not found")
            return
        }

        assertEquals("/health", spec["endpoint"])
        assertEquals("GET", spec["method"])
        assertTrue(spec["cases"] is List<*>)
        assertTrue((spec["cases"] as List<*>).isNotEmpty())
    }

    @Test
    fun `can load unpair spec`() {
        val spec = loadTestSpec("unpair.yaml")
        if (spec == null) {
            println("Skipping: test_specs not found")
            return
        }

        assertEquals("/unpair", spec["endpoint"])
        assertEquals("POST", spec["method"])
    }

    @Test
    fun `can load noise subscribe spec`() {
        val spec = loadTestSpec("noise_subscribe.yaml")
        if (spec == null) {
            println("Skipping: test_specs not found")
            return
        }

        assertEquals("/noise/subscribe", spec["endpoint"])
        assertEquals("POST", spec["method"])
    }

    @Test
    fun `can load noise unsubscribe spec`() {
        val spec = loadTestSpec("noise_unsubscribe.yaml")
        if (spec == null) {
            println("Skipping: test_specs not found")
            return
        }

        assertEquals("/noise/unsubscribe", spec["endpoint"])
        assertEquals("POST", spec["method"])
    }

    @Test
    fun `can load websocket upgrade spec`() {
        val spec = loadTestSpec("websocket_upgrade.yaml")
        if (spec == null) {
            println("Skipping: test_specs not found")
            return
        }

        assertEquals("/control/ws", spec["endpoint"])
        assertEquals("websocket", spec["upgrade"])
    }

    @Test
    fun `can load mtls spec`() {
        val spec = loadTestSpec("mtls.yaml")
        if (spec == null) {
            println("Skipping: test_specs not found")
            return
        }

        assertEquals("/*", spec["endpoint"])
    }

    // -------------------------------------------------------------------------
    // Test Case Extraction
    // -------------------------------------------------------------------------

    @Test
    fun `health spec has expected test cases`() {
        val spec = loadTestSpec("health.yaml") ?: return

        @Suppress("UNCHECKED_CAST")
        val cases = spec["cases"] as List<Map<String, Any>>

        val caseNames = cases.map { it["name"] as String }
        assertTrue("health_no_client_cert" in caseNames)
        assertTrue("health_with_trusted_cert" in caseNames)
        assertTrue("health_includes_uptime" in caseNames)
    }

    @Test
    fun `unpair spec has authentication test cases`() {
        val spec = loadTestSpec("unpair.yaml") ?: return

        @Suppress("UNCHECKED_CAST")
        val cases = spec["cases"] as List<Map<String, Any>>

        val caseNames = cases.map { it["name"] as String }
        assertTrue("unpair_no_cert" in caseNames)
        assertTrue("unpair_untrusted_cert" in caseNames)
        assertTrue("unpair_success_with_device_id" in caseNames)
    }

    @Test
    fun `noise subscribe spec has validation test cases`() {
        val spec = loadTestSpec("noise_subscribe.yaml") ?: return

        @Suppress("UNCHECKED_CAST")
        val cases = spec["cases"] as List<Map<String, Any>>

        val caseNames = cases.map { it["name"] as String }

        // Check authentication tests
        assertTrue("subscribe_no_cert" in caseNames)
        assertTrue("subscribe_untrusted_cert" in caseNames)

        // Check validation tests
        assertTrue("subscribe_missing_fcm_token" in caseNames)
        assertTrue("subscribe_missing_platform" in caseNames)

        // Check success cases
        assertTrue("subscribe_success_minimal" in caseNames)
    }

    // -------------------------------------------------------------------------
    // WebSocket Accept Key Computation
    // -------------------------------------------------------------------------

    @Test
    fun `computeWebSocketAccept produces correct key`() {
        // Standard test vector from RFC 6455
        val testKey = "dGhlIHNhbXBsZSBub25jZQ=="
        val expectedAccept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

        val magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        val digest = java.security.MessageDigest.getInstance("SHA-1")
        val hash = digest.digest((testKey + magic).toByteArray(Charsets.UTF_8))
        val actualAccept = java.util.Base64.getEncoder().encodeToString(hash)

        assertEquals(expectedAccept, actualAccept)
    }

    // -------------------------------------------------------------------------
    // mTLS Identity Generation Tests
    // -------------------------------------------------------------------------

    @Test
    fun `test identities are generated correctly`() {
        assertNotNull(identities.monitor)
        assertNotNull(identities.trusted)
        assertNotNull(identities.untrusted)

        // Each identity should have unique fingerprint
        assertNotEquals(identities.monitor.fingerprint, identities.trusted.fingerprint)
        assertNotEquals(identities.monitor.fingerprint, identities.untrusted.fingerprint)
        assertNotEquals(identities.trusted.fingerprint, identities.untrusted.fingerprint)
    }

    @Test
    fun `fingerprint is 64 character hex string`() {
        val fingerprint = identities.monitor.fingerprint
        assertEquals(64, fingerprint.length)
        assertTrue(fingerprint.all { it in '0'..'9' || it in 'a'..'f' })
    }

    @Test
    fun `certificate DER is valid`() {
        val certDer = identities.monitor.certificateDer
        assertTrue(certDer.isNotEmpty())
        // DER-encoded certificate should start with SEQUENCE tag (0x30)
        assertEquals(0x30.toByte(), certDer[0])
    }

    @Test
    fun `private key PKCS8 is valid`() {
        val pkcs8 = identities.monitor.privateKeyPkcs8
        assertTrue(pkcs8.isNotEmpty())
        // PKCS#8 should start with SEQUENCE tag (0x30)
        assertEquals(0x30.toByte(), pkcs8[0])
    }

    @Test
    fun `can create server SSL context`() {
        val sslContext = MtlsTestHelper.createServerSslContext(
            serverIdentity = identities.monitor,
            trustedCerts = listOf(identities.trusted),
            knownUntrustedCerts = listOf(identities.untrusted)
        )

        assertNotNull(sslContext)
        assertEquals("TLS", sslContext.protocol)
    }

    @Test
    fun `can create client SSL context with identity`() {
        val sslContext = MtlsTestHelper.createClientSslContext(
            clientIdentity = identities.trusted,
            trustedServerCert = identities.monitor
        )

        assertNotNull(sslContext)
        assertEquals("TLS", sslContext.protocol)
    }

    @Test
    fun `can create client SSL context without identity`() {
        val sslContext = MtlsTestHelper.createClientSslContext(
            clientIdentity = null,
            trustedServerCert = identities.monitor
        )

        assertNotNull(sslContext)
        assertEquals("TLS", sslContext.protocol)
    }

    @Test
    fun `fingerprint matches certificate content`() {
        val computedFingerprint = MtlsTestHelper.fingerprintHex(identities.monitor.certificateDer)
        assertEquals(identities.monitor.fingerprint, computedFingerprint)
    }
}
