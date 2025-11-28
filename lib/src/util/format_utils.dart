/// Utility functions for formatting values for display.
library;

/// Returns shortened fingerprint for display (first 12 characters).
///
/// Used for consistent fingerprint display across the UI.
/// Example: 'a1b2c3d4e5f6g7h8i9j0k1l2' -> 'a1b2c3d4e5f6'
String shortFingerprint(String fingerprint) {
  if (fingerprint.length <= 12) return fingerprint;
  return fingerprint.substring(0, 12);
}
