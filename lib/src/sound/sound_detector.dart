import 'dart:math';

import '../domain/models.dart';

class DetectedNoise {
  DetectedNoise({required this.timestampMs, required this.peakLevel});

  final int timestampMs;
  final int peakLevel;
}

typedef NoiseCallback = void Function(DetectedNoise event);
typedef LevelCallback = void Function(int level);

class SoundDetector {
  final NoiseSettings settings;
  final NoiseCallback onNoise;
  final LevelCallback? onLevel;
  final int sampleRate;
  final int frameSize;

  final int _frameDurationMs;
  late final int _cooldownMs;
  int _loudDurationMs = 0;
  late int _lastEventMs;
  int _peakLevel = 0;

  void addFrame(List<double> samples, {required int timestampMs}) {
    if (samples.isEmpty) return;
    final level = _levelFromSamples(samples);
    onLevel?.call(level);
    _peakLevel = max(_peakLevel, level);

    if (level >= settings.threshold) {
      _loudDurationMs += _frameDurationMs;
    } else {
      _loudDurationMs = 0;
      _peakLevel = 0;
    }

    final inCooldown = timestampMs - _lastEventMs < _cooldownMs;

    if (_loudDurationMs >= settings.minDurationMs && !inCooldown) {
      _lastEventMs = timestampMs;
      onNoise(DetectedNoise(timestampMs: timestampMs, peakLevel: _peakLevel));
      _loudDurationMs = 0;
      _peakLevel = 0;
    }
  }

  int _levelFromSamples(List<double> samples) {
    final sumSq = samples.fold<double>(0, (acc, s) => acc + s * s);
    final rms = sqrt(sumSq / samples.length);

    // Convert to dB scale for more useful level values.
    // RMS of 1.0 (max) -> 0 dB, typical speech ~0.05-0.1 -> -26 to -20 dB
    // Map -60 dB to 0 and 0 dB to 100.
    if (rms < 1e-10) return 0; // Silence
    final db = 20 * log(rms) / ln10;
    // db ranges from ~-60 (silence) to 0 (max)
    // Map to 0-100 scale: level = (db + 60) * 100 / 60
    final level = ((db + 60) * 100 / 60).clamp(0, 100);
    return level.round();
  }

  SoundDetector._internal({
    required this.settings,
    required this.onNoise,
    this.onLevel,
    required this.sampleRate,
    required this.frameSize,
    required int frameDurationMs,
  }) : _frameDurationMs = frameDurationMs;

  factory SoundDetector({
    required NoiseSettings settings,
    required NoiseCallback onNoise,
    LevelCallback? onLevel,
    int sampleRate = 16000,
    int frameSize = 320,
  }) {
    final frameDurationMs = ((frameSize / sampleRate) * 1000).round();
    final detector = SoundDetector._internal(
      settings: settings,
      onNoise: onNoise,
      onLevel: onLevel,
      sampleRate: sampleRate,
      frameSize: frameSize,
      frameDurationMs: frameDurationMs,
    );
    detector._cooldownMs = settings.cooldownSeconds * 1000;
    detector._lastEventMs = -detector._cooldownMs;
    return detector;
  }
}
