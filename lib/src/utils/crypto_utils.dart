/// Cryptographic utility functions used across the application.
///
/// Centralizes common crypto operations to avoid duplication.
library;

import 'package:crypto/crypto.dart' show sha256;

/// Computes the SHA-256 fingerprint of bytes and returns as a lowercase hex string.
///
/// Used primarily for certificate fingerprinting in mTLS operations.
///
/// Example:
/// ```dart
/// final fingerprint = fingerprintHex(certificateDer);
/// // Returns: 'a1b2c3d4e5f6...' (64 character hex string)
/// ```
String fingerprintHex(List<int> bytes) {
  final digest = sha256.convert(bytes);
  return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
