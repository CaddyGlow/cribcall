import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform-agnostic audio playback service for playing raw PCM audio.
/// Used by the listener to play audio received via WebRTC data channel.
abstract class AudioPlaybackService {
  /// Whether the playback service is currently running.
  bool get isRunning;

  /// Start the audio playback service.
  Future<bool> start();

  /// Stop the audio playback service.
  Future<void> stop();

  /// Write raw PCM audio data (16-bit signed little-endian mono 16kHz).
  Future<void> write(Uint8List data);

  /// Factory to create platform-appropriate implementation.
  factory AudioPlaybackService() {
    if (!kIsWeb && Platform.isAndroid) {
      return AndroidAudioPlaybackService();
    }
    if (!kIsWeb && Platform.isLinux) {
      return LinuxAudioPlaybackService();
    }
    // Other platforms: no-op for now
    return NoopAudioPlaybackService();
  }
}

/// Android audio playback using platform channel to AudioTrack.
class AndroidAudioPlaybackService implements AudioPlaybackService {
  AndroidAudioPlaybackService({
    MethodChannel? methodChannel,
  }) : _method = methodChannel ?? const MethodChannel('cribcall/audio_playback');

  final MethodChannel _method;
  bool _isRunning = false;

  @override
  bool get isRunning => _isRunning;

  @override
  Future<bool> start() async {
    if (_isRunning) return true;

    try {
      final result = await _method.invokeMethod<bool>('start');
      _isRunning = result == true;
      debugPrint('[audio_playback] Audio playback started: $_isRunning');
      return _isRunning;
    } catch (e) {
      debugPrint('[audio_playback] Failed to start audio playback: $e');
      return false;
    }
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;

    try {
      await _method.invokeMethod<void>('stop');
      _isRunning = false;
      debugPrint('[audio_playback] Audio playback stopped');
    } catch (e) {
      debugPrint('[audio_playback] Error stopping audio playback: $e');
    }
  }

  @override
  Future<void> write(Uint8List data) async {
    if (!_isRunning) return;

    try {
      await _method.invokeMethod<void>('write', {'data': data});
    } catch (e) {
      // Don't log every write error to avoid spam
    }
  }
}

/// Linux audio playback using PipeWire (pw-play) or PulseAudio (paplay) subprocess.
/// Streams signed 16-bit little-endian mono PCM at 16kHz.
class LinuxAudioPlaybackService implements AudioPlaybackService {
  Process? _process;
  IOSink? _stdin;
  bool _isRunning = false;
  int _writeCount = 0;

  @override
  bool get isRunning => _isRunning;

  @override
  Future<bool> start() async {
    if (_isRunning) return true;

    // Try pw-play first (PipeWire native), fall back to paplay (PulseAudio)
    final commands = [
      [
        'pw-play',
        '--raw',
        '--rate=16000',
        '--channels=1',
        '--format=s16',
        '/dev/stdin',
      ],
      [
        'paplay',
        '--rate=16000',
        '--channels=1',
        '--format=s16le',
        '--raw',
      ],
    ];

    for (final cmd in commands) {
      try {
        debugPrint('[audio_playback] Trying audio playback with: ${cmd.first}');
        _process = await Process.start(cmd.first, cmd.skip(1).toList());
        _stdin = _process!.stdin;
        _isRunning = true;
        debugPrint('[audio_playback] Started audio playback with ${cmd.first} (pid=${_process!.pid})');

        // Log stderr for debugging
        _process!.stderr.transform(const SystemEncoding().decoder).listen((line) {
          debugPrint('[audio_playback] stderr: $line');
        });

        // Log stdout for debugging
        _process!.stdout.transform(const SystemEncoding().decoder).listen((line) {
          debugPrint('[audio_playback] stdout: $line');
        });

        // Handle process exit
        _process!.exitCode.then((code) {
          debugPrint('[audio_playback] Process exited with code: $code');
          _isRunning = false;
        });

        return true;
      } catch (e) {
        debugPrint('[audio_playback] ${cmd.first} not available: $e');
      }
    }

    debugPrint('[audio_playback] No audio playback tool available (tried pw-play, paplay)');
    return false;
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;

    _isRunning = false;
    try {
      await _stdin?.close();
    } catch (e) {
      debugPrint('[audio_playback] Error closing stdin: $e');
    }
    _stdin = null;

    _process?.kill(ProcessSignal.sigterm);
    _process = null;
    _writeCount = 0;
    debugPrint('[audio_playback] Audio playback stopped');
  }

  @override
  Future<void> write(Uint8List data) async {
    if (!_isRunning || _stdin == null) {
      if (_writeCount == 0) {
        debugPrint('[audio_playback] write called but not running (isRunning=$_isRunning, stdin=${_stdin != null})');
      }
      return;
    }

    try {
      _stdin!.add(data);
      _writeCount++;
      if (_writeCount == 1 || _writeCount % 100 == 0) {
        // Calculate peak level to verify audio isn't silent
        final peak = _calculatePeakLevel(data);
        debugPrint('[audio_playback] write #$_writeCount (${data.length} bytes, peak=$peak)');
      }
    } catch (e) {
      debugPrint('[audio_playback] write error: $e');
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
}

/// No-op fallback for platforms without playback implemented.
class NoopAudioPlaybackService implements AudioPlaybackService {
  @override
  bool get isRunning => false;

  @override
  Future<bool> start() async => false;

  @override
  Future<void> stop() async {}

  @override
  Future<void> write(Uint8List data) async {}
}
