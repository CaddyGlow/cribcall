import 'package:cribcall/src/domain/models.dart';
import 'package:cribcall/src/sound/sound_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('emits noise event after exceeding threshold for min duration', () {
    final events = <DetectedNoise>[];
    final detector = SoundDetector(
      settings: const NoiseSettings(
        threshold: 60,
        minDurationMs: 60,
        cooldownSeconds: 2,
      ),
      onNoise: events.add,
      sampleRate: 16000,
      frameSize: 320, // 20 ms
    );

    final loudFrame = List<double>.filled(320, 0.8); // level ~80

    detector.addFrame(loudFrame, timestampMs: 0); // 20ms
    detector.addFrame(loudFrame, timestampMs: 20); // 40ms
    detector.addFrame(loudFrame, timestampMs: 40); // 60ms -> should trigger

    expect(events.length, 1);
    expect(events.first.peakLevel, greaterThanOrEqualTo(80));
  });

  test('resets loud duration when falling below threshold', () {
    final events = <DetectedNoise>[];
    final detector = SoundDetector(
      settings: const NoiseSettings(
        threshold: 60,
        minDurationMs: 60,
        cooldownSeconds: 2,
      ),
      onNoise: events.add,
      sampleRate: 16000,
      frameSize: 320,
    );

    final loudFrame = List<double>.filled(320, 0.8);
    final quietFrame = List<double>.filled(320, 0.1);

    detector.addFrame(loudFrame, timestampMs: 0); // 20ms
    detector.addFrame(quietFrame, timestampMs: 20); // reset
    detector.addFrame(loudFrame, timestampMs: 40);
    detector.addFrame(loudFrame, timestampMs: 60);
    detector.addFrame(
      loudFrame,
      timestampMs: 80,
    ); // should trigger after new accumulation

    expect(events.length, 1);
  });

  test('honors cooldown between events', () {
    final events = <DetectedNoise>[];
    final detector = SoundDetector(
      settings: const NoiseSettings(
        threshold: 50,
        minDurationMs: 40,
        cooldownSeconds: 3,
      ),
      onNoise: events.add,
      sampleRate: 16000,
      frameSize: 320,
    );

    final loudFrame = List<double>.filled(320, 0.9);

    detector.addFrame(loudFrame, timestampMs: 0);
    detector.addFrame(loudFrame, timestampMs: 20);
    detector.addFrame(loudFrame, timestampMs: 40); // event 1
    detector.addFrame(loudFrame, timestampMs: 60);
    detector.addFrame(loudFrame, timestampMs: 80); // still in cooldown
    detector.addFrame(loudFrame, timestampMs: 3100); // after cooldown
    detector.addFrame(loudFrame, timestampMs: 3120); // event 2

    expect(events.length, 2);
  });
}
