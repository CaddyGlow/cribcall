import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

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

/// Linux audio capture using PipeWire (pw-record) or PulseAudio (parec) subprocess.
/// Streams signed 16-bit little-endian mono PCM at [sampleRate] Hz.
class LinuxSubprocessAudioCaptureService extends AudioCaptureService {
  LinuxSubprocessAudioCaptureService({
    required super.settings,
    required super.onNoise,
    super.sampleRate,
    super.frameSize,
  });

  Process? _process;
  StreamSubscription<List<int>>? _stdoutSub;
  final _buffer = BytesBuilder(copy: false);
  int _bytesPerFrame = 0;

  @override
  Future<void> start() async {
    if (_process != null) return;

    _bytesPerFrame = frameSize * 2; // 16-bit = 2 bytes per sample

    // Try pw-record first (PipeWire native), fall back to parec (PulseAudio)
    final commands = [
      [
        'pw-record',
        '--rate=$sampleRate',
        '--channels=1',
        '--format=s16',
        '--target=@DEFAULT_AUDIO_SOURCE@',
        '-',
      ],
      [
        'parec',
        '--rate=$sampleRate',
        '--channels=1',
        '--format=s16le',
        '--raw',
      ],
    ];

    for (final cmd in commands) {
      try {
        developer.log(
          'Trying audio capture with: ${cmd.first}',
          name: 'audio_capture',
        );
        _process = await Process.start(cmd.first, cmd.skip(1).toList());
        developer.log(
          'Started audio capture with ${cmd.first} (pid=${_process!.pid})',
          name: 'audio_capture',
        );
        break;
      } catch (e) {
        developer.log(
          '${cmd.first} not available: $e',
          name: 'audio_capture',
        );
      }
    }

    if (_process == null) {
      developer.log(
        'No audio capture tool available (tried pw-record, parec)',
        name: 'audio_capture',
      );
      return;
    }

    _stdoutSub = _process!.stdout.listen(
      _onData,
      onError: (Object e) {
        developer.log('Audio capture stream error: $e', name: 'audio_capture');
      },
      onDone: () {
        developer.log('Audio capture stream ended', name: 'audio_capture');
      },
    );

    // Log stderr for debugging
    _process!.stderr.transform(const SystemEncoding().decoder).listen((line) {
      developer.log('Audio capture stderr: $line', name: 'audio_capture');
    });
  }

  void _onData(List<int> chunk) {
    _buffer.add(chunk);
    final bytes = Uint8List.fromList(_buffer.takeBytes());
    var offset = 0;

    while (offset + _bytesPerFrame <= bytes.length) {
      final frameBytes = Uint8List.sublistView(bytes, offset, offset + _bytesPerFrame);
      final samples = _pcmBytesToSamples(frameBytes);
      final timestampMs = DateTime.now().millisecondsSinceEpoch;
      detector.addFrame(samples, timestampMs: timestampMs);
      offset += _bytesPerFrame;
    }

    // Keep remaining bytes for next chunk
    if (offset < bytes.length) {
      _buffer.add(bytes.sublist(offset));
    }
  }

  List<double> _pcmBytesToSamples(Uint8List bytes) {
    final samples = <double>[];
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < bytes.length; i += 2) {
      final int16 = data.getInt16(i, Endian.little);
      samples.add(int16 / 32768.0);
    }
    return samples;
  }

  @override
  Future<void> stop() async {
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    _process?.kill(ProcessSignal.sigterm);
    _process = null;
    _buffer.clear();
    developer.log('Audio capture stopped', name: 'audio_capture');
  }
}

/// Legacy alias for backwards compatibility.
typedef PipewireAudioCaptureService = LinuxSubprocessAudioCaptureService;

/// Android audio capture using platform channels to AudioRecord.
/// Receives signed 16-bit little-endian mono PCM at [sampleRate] Hz.
class AndroidAudioCaptureService extends AudioCaptureService {
  AndroidAudioCaptureService({
    required super.settings,
    required super.onNoise,
    super.sampleRate,
    super.frameSize,
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _method = methodChannel ?? const MethodChannel('cribcall/audio'),
       _events = eventChannel ?? const EventChannel('cribcall/audio_events');

  final MethodChannel _method;
  final EventChannel _events;
  StreamSubscription<dynamic>? _subscription;
  final _buffer = BytesBuilder(copy: false);
  int _bytesPerFrame = 0;

  @override
  Future<void> start() async {
    if (_subscription != null) return;

    _bytesPerFrame = frameSize * 2; // 16-bit = 2 bytes per sample

    // Check/request permission first
    final hasPermission = await _method.invokeMethod<bool>('hasPermission');
    if (hasPermission != true) {
      developer.log('Requesting audio permission', name: 'audio_capture');
      await _method.invokeMethod<bool>('requestPermission');
      // Wait a moment for permission dialog
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    // Start listening to the event channel
    _subscription = _events.receiveBroadcastStream().listen(
      _onData,
      onError: (Object e) {
        developer.log('Audio capture stream error: $e', name: 'audio_capture');
      },
      onDone: () {
        developer.log('Audio capture stream ended', name: 'audio_capture');
      },
    );

    try {
      await _method.invokeMethod<void>('start');
      developer.log(
        'Started Android audio capture',
        name: 'audio_capture',
      );
    } catch (e) {
      developer.log('Failed to start audio capture: $e', name: 'audio_capture');
      await _subscription?.cancel();
      _subscription = null;
    }
  }

  void _onData(dynamic data) {
    if (data is! Uint8List) return;

    _buffer.add(data);
    final bytes = Uint8List.fromList(_buffer.takeBytes());
    var offset = 0;

    while (offset + _bytesPerFrame <= bytes.length) {
      final frameBytes = Uint8List.sublistView(bytes, offset, offset + _bytesPerFrame);
      final samples = _pcmBytesToSamples(frameBytes);
      final timestampMs = DateTime.now().millisecondsSinceEpoch;
      detector.addFrame(samples, timestampMs: timestampMs);
      offset += _bytesPerFrame;
    }

    // Keep remaining bytes for next chunk
    if (offset < bytes.length) {
      _buffer.add(bytes.sublist(offset));
    }
  }

  List<double> _pcmBytesToSamples(Uint8List bytes) {
    final samples = <double>[];
    final byteData = ByteData.sublistView(bytes);
    for (var i = 0; i < bytes.length; i += 2) {
      final int16 = byteData.getInt16(i, Endian.little);
      samples.add(int16 / 32768.0);
    }
    return samples;
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _buffer.clear();
    try {
      await _method.invokeMethod<void>('stop');
    } catch (e) {
      developer.log('Error stopping audio capture: $e', name: 'audio_capture');
    }
    developer.log('Android audio capture stopped', name: 'audio_capture');
  }
}
