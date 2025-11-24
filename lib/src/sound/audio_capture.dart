import 'dart:async';

import '../domain/models.dart';
import 'sound_detector.dart';

typedef NoiseEventSink = FutureOr<void> Function(DetectedNoise event);

/// Platform-agnostic audio capture shim. Platform code should implement
/// [start] to stream PCM frames into the provided [SoundDetector].
abstract class AudioCaptureService {
  AudioCaptureService({
    required NoiseSettings settings,
    required NoiseEventSink onNoise,
    this.sampleRate = 16000,
    this.frameSize = 320,
  }) : detector = SoundDetector(
         settings: settings,
         onNoise: (event) => onNoise(event),
         sampleRate: sampleRate,
         frameSize: frameSize,
       );

  final int sampleRate;
  final int frameSize;
  final SoundDetector detector;

  Future<void> start();
  Future<void> stop();
}

/// No-op fallback for platforms without capture wired yet.
class NoopAudioCaptureService extends AudioCaptureService {
  NoopAudioCaptureService({required super.settings, required super.onNoise});

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

/// Placeholder for a PipeWire-backed capture on Linux. Implementations should
/// stream PCM frames into [detector].
class PipewireAudioCaptureService extends AudioCaptureService {
  PipewireAudioCaptureService({
    required super.settings,
    required super.onNoise,
    super.sampleRate,
    super.frameSize,
  });

  @override
  Future<void> start() async {
    // TODO: Integrate PipeWire capture and feed frames to detector.addFrame.
  }

  @override
  Future<void> stop() async {}
}
