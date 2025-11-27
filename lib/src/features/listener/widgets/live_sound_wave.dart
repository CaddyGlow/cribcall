import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../theme.dart';

/// Animated sound wave visualization for the listener when live.
///
/// Shows a center-origin waveform that animates based on received audio data.
/// When no audio data is flowing, shows a gentle idle animation.
class LiveSoundWave extends StatefulWidget {
  const LiveSoundWave({
    super.key,
    required this.audioStream,
    this.barCount = 32,
    this.height = 80,
  });

  /// Stream of audio data (PCM bytes).
  final Stream<Uint8List> audioStream;

  /// Number of bars in the waveform.
  final int barCount;

  /// Height of the waveform widget.
  final double height;

  @override
  State<LiveSoundWave> createState() => _LiveSoundWaveState();
}

class _LiveSoundWaveState extends State<LiveSoundWave>
    with SingleTickerProviderStateMixin {
  late AnimationController _idleController;
  StreamSubscription<Uint8List>? _audioSubscription;

  /// Current levels for each bar (0.0 - 1.0).
  late List<double> _levels;

  /// Target levels that bars animate towards.
  late List<double> _targetLevels;

  /// Time of last audio data received.
  DateTime _lastAudioTime = DateTime.now();

  /// Whether we're receiving active audio.
  bool get _hasActiveAudio =>
      DateTime.now().difference(_lastAudioTime).inMilliseconds < 200;

  @override
  void initState() {
    super.initState();
    _levels = List.filled(widget.barCount, 0.0);
    _targetLevels = List.filled(widget.barCount, 0.0);

    _idleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 50),
    )..addListener(_updateLevels);

    _idleController.repeat();
    _subscribeToAudio();
  }

  void _subscribeToAudio() {
    _audioSubscription = widget.audioStream.listen(_onAudioData);
  }

  void _onAudioData(Uint8List data) {
    _lastAudioTime = DateTime.now();

    // Calculate levels from PCM data
    // Assume 16-bit PCM samples
    if (data.length < 2) return;

    final sampleCount = data.length ~/ 2;
    final samplesPerBar = math.max(1, sampleCount ~/ widget.barCount);

    for (var i = 0; i < widget.barCount; i++) {
      var maxSample = 0;
      final startSample = i * samplesPerBar;
      final endSample = math.min(startSample + samplesPerBar, sampleCount);

      for (var j = startSample; j < endSample; j++) {
        final byteIndex = j * 2;
        if (byteIndex + 1 < data.length) {
          // Little-endian 16-bit signed
          final sample = (data[byteIndex] | (data[byteIndex + 1] << 8));
          final signedSample = sample > 32767 ? sample - 65536 : sample;
          maxSample = math.max(maxSample, signedSample.abs());
        }
      }

      // Normalize to 0-1 range (16-bit audio max is 32768)
      _targetLevels[i] = (maxSample / 32768.0).clamp(0.0, 1.0);
    }
  }

  void _updateLevels() {
    if (!mounted) return;

    setState(() {
      if (_hasActiveAudio) {
        // Smoothly interpolate towards target levels
        for (var i = 0; i < widget.barCount; i++) {
          _levels[i] = _levels[i] + (_targetLevels[i] - _levels[i]) * 0.4;
          // Decay target levels
          _targetLevels[i] *= 0.85;
        }
      } else {
        // Idle animation - gentle wave
        final time = DateTime.now().millisecondsSinceEpoch / 1000.0;
        for (var i = 0; i < widget.barCount; i++) {
          final phase = (i / widget.barCount) * math.pi * 2;
          final wave1 = math.sin(time * 2 + phase) * 0.15;
          final wave2 = math.sin(time * 3.5 + phase * 1.5) * 0.1;
          _levels[i] = 0.08 + wave1.abs() + wave2.abs();
        }
      }
    });
  }

  @override
  void didUpdateWidget(LiveSoundWave oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audioStream != widget.audioStream) {
      _audioSubscription?.cancel();
      _subscribeToAudio();
    }
    if (oldWidget.barCount != widget.barCount) {
      _levels = List.filled(widget.barCount, 0.0);
      _targetLevels = List.filled(widget.barCount, 0.0);
    }
  }

  @override
  void dispose() {
    _audioSubscription?.cancel();
    _idleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: CustomPaint(
        painter: _SoundWavePainter(
          levels: _levels,
          color: _hasActiveAudio ? AppColors.success : AppColors.primary,
          glowColor: _hasActiveAudio
              ? AppColors.success.withValues(alpha: 0.3)
              : AppColors.primary.withValues(alpha: 0.2),
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _SoundWavePainter extends CustomPainter {
  _SoundWavePainter({
    required this.levels,
    required this.color,
    required this.glowColor,
  });

  final List<double> levels;
  final Color color;
  final Color glowColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;

    final centerY = size.height / 2;
    final barWidth = size.width / levels.length;
    const barSpacing = 2.0;
    final maxBarHeight = size.height * 0.9;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final glowPaint = Paint()
      ..color = glowColor
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    for (var i = 0; i < levels.length; i++) {
      final level = levels[i];
      final barHeight = math.max(4.0, level * maxBarHeight);
      final x = i * barWidth + barSpacing / 2;
      final actualBarWidth = barWidth - barSpacing;

      // Draw glow
      final glowRect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x + actualBarWidth / 2, centerY),
          width: actualBarWidth,
          height: barHeight,
        ),
        const Radius.circular(2),
      );
      canvas.drawRRect(glowRect, glowPaint);

      // Draw bar (from center, extending both up and down)
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x + actualBarWidth / 2, centerY),
          width: actualBarWidth,
          height: barHeight,
        ),
        const Radius.circular(2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_SoundWavePainter oldDelegate) {
    return true; // Always repaint for smooth animation
  }
}
