// Minimal stand-in for flutter/foundation.dart so console tools can run
// without dart:ui. Only the APIs we use in CLI contexts are provided.

const bool kIsWeb = false;

// In CLI mode, we consider it debug mode when assertions are enabled.
// This mirrors Flutter's kDebugMode behavior.
const bool kDebugMode = bool.fromEnvironment('dart.vm.product') == false;

void debugPrint(String? message, {int? wrapWidth}) {
  if (message == null) return;
  // Ignore wrapWidth in console mode; rely on stdout.
  // Use stdout via print to avoid pulling in dart:ui.
  print(message);
}
