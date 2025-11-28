import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../domain/audio.dart';
import '../domain/models.dart';
import 'sound_detector.dart';

typedef NoiseEventSink = FutureOr<void> Function(DetectedNoise event);
typedef LevelSink = void Function(int level);

/// Platform-agnostic audio capture shim. Platform code should implement
/// [start] to stream PCM frames into the provided [SoundDetector].
abstract class AudioCaptureService {
  AudioCaptureService({
    required NoiseSettings settings,
    required NoiseEventSink onNoise,
    LevelSink? onLevel,
    double inputGain = 1.0,
    this.sampleRate = 16000,
    this.frameSize = 320,
  }) : detector = SoundDetector(
         settings: settings,
         onNoise: (event) => onNoise(event),
         onLevel: onLevel,
         sampleRate: sampleRate,
         frameSize: frameSize,
       ),
       _inputGain = inputGain.clamp(0.0, 2.0);

  final int sampleRate;
  final int frameSize;
  final SoundDetector detector;
  double _inputGain;

  /// Stream controller for raw PCM audio data (for WebRTC streaming).
  final _rawDataController = StreamController<Uint8List>.broadcast();

  /// Stream of raw PCM audio data (16-bit signed little-endian mono).
  /// Subscribe to this for WebRTC streaming.
  Stream<Uint8List> get rawAudioStream => _rawDataController.stream;

  int _emitCount = 0;

  /// Emit raw audio data to subscribers.
  void emitRawData(Uint8List data) {
    if (!_rawDataController.isClosed) {
      _rawDataController.add(data);
      _emitCount++;
      if (_emitCount == 1 || _emitCount % 100 == 0) {
        // Calculate peak level to verify audio isn't silent
        final peak = _calculatePeakLevel(data);
        developer.log(
          'emitRawData: packet #$_emitCount (${data.length} bytes, peak=$peak, listeners=${_rawDataController.hasListener})',
          name: 'audio_capture',
        );
      }
    }
  }

  /// Calculate peak audio level from PCM data (0-32768 range).
  int _calculatePeakLevel(Uint8List data) {
    if (data.length < 2) return 0;
    final byteData = ByteData.sublistView(data);
    int peak = 0;
    for (var i = 0; i < data.length - 1; i += 2) {
      final sample = byteData.getInt16(i, Endian.little).abs();
      if (sample > peak) peak = sample;
    }
    return peak;
  }

  /// Apply input gain (0.0-2.0) to PCM bytes, clamping to 16-bit range.
  /// Returns the original buffer when gain is 1.0 to avoid extra copies.
  Uint8List applyInputGain(Uint8List data) {
    if (_inputGain == 1.0 || data.isEmpty) return data;

    final out = Uint8List(data.length);
    final input = ByteData.sublistView(data);
    final output = ByteData.sublistView(out);

    for (var i = 0; i < data.length - 1; i += 2) {
      final sample = input.getInt16(i, Endian.little);
      final scaled = (sample * _inputGain).round().clamp(-32768, 32767);
      output.setInt16(i, scaled, Endian.little);
    }

    return out;
  }

  void setInputGain(double gain) {
    _inputGain = gain.clamp(0.0, 2.0);
  }

  Future<void> start();

  Future<void> stop() async {
    await _rawDataController.close();
  }
}

/// No-op fallback for platforms without capture wired yet.
class NoopAudioCaptureService extends AudioCaptureService {
  NoopAudioCaptureService({
    required super.settings,
    required super.onNoise,
    super.onLevel,
  });

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    await super.stop();
  }
}

/// Debug audio capture that captures from the virtual mic (cribcall_virtual.monitor).
/// Used for testing on Linux - captures real audio that WebRTC also streams.
/// Call [injectTestNoise] to play a tone into the virtual sink.
class DebugAudioCaptureService extends AudioCaptureService {
  DebugAudioCaptureService({
    required super.settings,
    required super.onNoise,
    super.onLevel,
    super.sampleRate,
    super.frameSize,
    super.inputGain,
  });

  Process? _recordProcess;
  StreamSubscription<List<int>>? _stdoutSub;
  final _buffer = BytesBuilder(copy: false);
  int _bytesPerFrame = 0;
  Process? _toneProcess;

  @override
  Future<void> start() async {
    if (_recordProcess != null) return;

    _bytesPerFrame = frameSize * 2; // 16-bit = 2 bytes per sample

    developer.log(
      'Starting debug audio capture from cribcall_virtual.monitor',
      name: 'audio_capture',
    );

    // Capture from the virtual mic monitor using pw-record or parec
    final commands = [
      [
        'pw-record',
        '--rate=$sampleRate',
        '--channels=1',
        '--format=s16',
        '--target=cribcall_virtual.monitor',
        '-',
      ],
      [
        'parec',
        '--rate=$sampleRate',
        '--channels=1',
        '--format=s16le',
        '--raw',
        '--device=cribcall_virtual.monitor',
      ],
    ];

    for (final cmd in commands) {
      try {
        developer.log(
          'Trying debug capture with: ${cmd.first}',
          name: 'audio_capture',
        );
        _recordProcess = await Process.start(cmd.first, cmd.skip(1).toList());
        developer.log(
          'Started debug capture with ${cmd.first} (pid=${_recordProcess!.pid})',
          name: 'audio_capture',
        );
        break;
      } catch (e) {
        developer.log('${cmd.first} not available: $e', name: 'audio_capture');
      }
    }

    if (_recordProcess == null) {
      developer.log(
        'No audio capture tool available - run scripts/setup-virtual-mic.sh first',
        name: 'audio_capture',
      );
      return;
    }

    _stdoutSub = _recordProcess!.stdout.listen(
      _onData,
      onError: (Object e) {
        developer.log('Debug capture stream error: $e', name: 'audio_capture');
      },
      onDone: () {
        developer.log('Debug capture stream ended', name: 'audio_capture');
      },
    );

    // Log stderr for debugging
    _recordProcess!.stderr.transform(const SystemEncoding().decoder).listen((
      line,
    ) {
      developer.log('Debug capture stderr: $line', name: 'audio_capture');
    });

    developer.log('Debug audio capture started', name: 'audio_capture');
  }

  void _onData(List<int> chunk) {
    _buffer.add(chunk);
    final bytes = Uint8List.fromList(_buffer.takeBytes());
    var offset = 0;

    while (offset + _bytesPerFrame <= bytes.length) {
      final frameBytes = Uint8List.sublistView(
        bytes,
        offset,
        offset + _bytesPerFrame,
      );
      final gained = applyInputGain(frameBytes);
      // Emit raw data for WebRTC streaming
      emitRawData(gained);
      final samples = _pcmBytesToSamples(gained);
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

  /// Inject a test noise burst by playing a tone into the virtual sink.
  /// This audio will be captured by both the waveform AND WebRTC.
  Future<void> injectTestNoise({int durationMs = 1500}) async {
    developer.log(
      'Injecting test noise (~${durationMs}ms)',
      name: 'audio_capture',
    );
    await _playTestTone(durationMs);
  }

  /// Play a test tone through the cribcall_virtual sink.
  /// This audio flows through the virtual mic and is captured by both
  /// the waveform (via pw-record) and WebRTC (via getUserMedia).
  Future<void> _playTestTone(int durationMs) async {
    // Kill any existing tone
    _toneProcess?.kill();
    _toneProcess = null;

    try {
      // Use pw-play with a generated tone file, or ffmpeg piped to pw-play
      _toneProcess = await Process.start('bash', [
        '-c',
        'ffmpeg -f lavfi -i "sine=frequency=440:duration=${durationMs / 1000}" '
            '-f wav -ar $sampleRate -ac 1 - 2>/dev/null | '
            'pw-play --target=cribcall_virtual -',
      ]);

      developer.log(
        'Playing test tone on cribcall_virtual sink',
        name: 'audio_capture',
      );

      // Auto-kill after duration + buffer
      Future.delayed(Duration(milliseconds: durationMs + 1000), () {
        _toneProcess?.kill();
        _toneProcess = null;
      });
    } catch (e) {
      developer.log('Could not play test tone: $e', name: 'audio_capture');
    }
  }

  @override
  Future<void> stop() async {
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    _recordProcess?.kill(ProcessSignal.sigterm);
    _recordProcess = null;
    _buffer.clear();
    _toneProcess?.kill();
    _toneProcess = null;
    developer.log('Debug audio capture stopped', name: 'audio_capture');
    await super.stop();
  }
}

/// Linux audio capture using PipeWire (pw-record) or PulseAudio (parec) subprocess.
/// Streams signed 16-bit little-endian mono PCM at [sampleRate] Hz.
class LinuxSubprocessAudioCaptureService extends AudioCaptureService {
  LinuxSubprocessAudioCaptureService({
    required super.settings,
    required super.onNoise,
    super.onLevel,
    super.sampleRate,
    super.frameSize,
    super.inputGain,
    this.deviceId,
  });

  final String? deviceId;
  Process? _process;
  StreamSubscription<List<int>>? _stdoutSub;
  final _buffer = BytesBuilder(copy: false);
  int _bytesPerFrame = 0;

  @override
  Future<void> start() async {
    if (_process != null) return;

    _bytesPerFrame = frameSize * 2; // 16-bit = 2 bytes per sample
    final pipewireTarget = _pipewireTarget();
    final parecDevice = _parecDeviceArg();

    developer.log(
      'Starting audio capture on device=${pipewireTarget == kDefaultAudioInputId ? "default" : pipewireTarget}',
      name: 'audio_capture',
    );

    // Try pw-record first (PipeWire native), fall back to parec (PulseAudio)
    final commands = [
      [
        'pw-record',
        '--rate=$sampleRate',
        '--channels=1',
        '--format=s16',
        '--target=$pipewireTarget',
        '-',
      ],
      [
        'parec',
        '--rate=$sampleRate',
        '--channels=1',
        '--format=s16le',
        '--raw',
        ...parecDevice,
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
        developer.log('${cmd.first} not available: $e', name: 'audio_capture');
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

  String _pipewireTarget() {
    final id = deviceId?.trim();
    if (id == null || id.isEmpty) return kDefaultAudioInputId;
    return id;
  }

  List<String> _parecDeviceArg() {
    final id = deviceId?.trim();
    if (id == null || id.isEmpty || id == kDefaultAudioInputId) {
      return const [];
    }
    return ['--device=$id'];
  }

  void _onData(List<int> chunk) {
    _buffer.add(chunk);
    final bytes = Uint8List.fromList(_buffer.takeBytes());
    var offset = 0;

    while (offset + _bytesPerFrame <= bytes.length) {
      final frameBytes = Uint8List.sublistView(
        bytes,
        offset,
        offset + _bytesPerFrame,
      );
      final gained = applyInputGain(frameBytes);
      // Emit raw data for WebRTC streaming
      emitRawData(gained);
      final samples = _pcmBytesToSamples(gained);
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
    await super.stop();
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
    super.onLevel,
    super.sampleRate,
    super.frameSize,
    super.inputGain,
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    this.mdnsAdvertisement,
  }) : _method = methodChannel ?? const MethodChannel('cribcall/audio'),
       _events = eventChannel ?? const EventChannel('cribcall/audio_events');

  final MethodChannel _method;
  final EventChannel _events;
  StreamSubscription<dynamic>? _subscription;
  final _buffer = BytesBuilder(copy: false);
  int _bytesPerFrame = 0;
  int _dataCount = 0;

  /// Optional mDNS advertisement to pass to the foreground service.
  /// On Android, the foreground service handles mDNS advertising.
  final MdnsAdvertisement? mdnsAdvertisement;

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
      // Pass mDNS params if available (for foreground service advertising)
      final params = <String, dynamic>{};
      if (mdnsAdvertisement != null) {
        params['remoteDeviceId'] = mdnsAdvertisement!.remoteDeviceId;
        params['monitorName'] = mdnsAdvertisement!.monitorName;
        params['certFingerprint'] = mdnsAdvertisement!.certFingerprint;
        params['controlPort'] = mdnsAdvertisement!.controlPort;
        params['pairingPort'] = mdnsAdvertisement!.pairingPort;
        params['version'] = mdnsAdvertisement!.version;
      }
      await _method.invokeMethod<void>(
        'start',
        params.isNotEmpty ? params : null,
      );
      developer.log(
        'Started Android audio capture${mdnsAdvertisement != null ? " with mDNS" : ""}',
        name: 'audio_capture',
      );
    } catch (e) {
      developer.log('Failed to start audio capture: $e', name: 'audio_capture');
      await _subscription?.cancel();
      _subscription = null;
    }
  }

  void _onData(dynamic data) {
    _dataCount++;
    if (_dataCount == 1 || _dataCount % 100 == 0) {
      developer.log(
        '_onData: received #$_dataCount (type=${data.runtimeType}, isUint8List=${data is Uint8List})',
        name: 'audio_capture',
      );
    }
    if (data is! Uint8List) return;

    _buffer.add(data);
    final bytes = Uint8List.fromList(_buffer.takeBytes());
    var offset = 0;

    while (offset + _bytesPerFrame <= bytes.length) {
      final frameBytes = Uint8List.sublistView(
        bytes,
        offset,
        offset + _bytesPerFrame,
      );
      final gained = applyInputGain(frameBytes);
      final samples = _pcmBytesToSamples(gained);
      emitRawData(gained);
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
    await super.stop();
  }
}
