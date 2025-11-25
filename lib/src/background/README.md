Platform-specific background plumbing:
- Android: bind NoopBackgroundServiceManager to a foreground service that keeps mic and control channel alive.
- iOS: enable background audio and keep AVAudioEngine running; map to BackgroundServiceManager.
These stubs keep the Dart side compiling until native code is added.
