// Minimal stand-in for flutter/foundation.dart so console tools can run
// without dart:ui. Only the APIs we use in CLI contexts are provided.

const bool kIsWeb = false;

void debugPrint(String? message, {int? wrapWidth}) {
  if (message == null) return;
  // Ignore wrapWidth in console mode; rely on stdout.
  // Use stdout via print to avoid pulling in dart:ui.
  print(message);
}
