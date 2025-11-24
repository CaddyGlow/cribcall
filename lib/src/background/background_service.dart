/// Stubs for background behavior per platform. Platform code should wire these
/// into foreground services (Android) or background audio modes (iOS).
abstract class BackgroundServiceManager {
  Future<void> startForegroundMonitoring();
  Future<void> stopForegroundMonitoring();
}

class NoopBackgroundServiceManager implements BackgroundServiceManager {
  @override
  Future<void> startForegroundMonitoring() async {}

  @override
  Future<void> stopForegroundMonitoring() async {}
}
