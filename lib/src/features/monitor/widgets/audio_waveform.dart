import 'package:flutter/material.dart';

import '../../../theme.dart';

/// Real-time audio level waveform visualization.
///
/// Shows the audio level history as bars with a threshold line overlay.
/// Bars above the threshold are displayed in warning color.
class AudioWaveform extends StatelessWidget {
  const AudioWaveform({
    super.key,
    required this.levelHistory,
    required this.currentLevel,
    required this.threshold,
    this.isDebugCapture = false,
  });

  final List<int> levelHistory;
  final int currentLevel;
  final int threshold;
  final bool isDebugCapture;

  @override
  Widget build(BuildContext context) {
    final isAboveThreshold = currentLevel >= threshold;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              isDebugCapture ? Icons.science : Icons.graphic_eq,
              size: 16,
              color: isDebugCapture ? Colors.orange.shade600 : AppColors.muted,
            ),
            const SizedBox(width: 6),
            Text(
              isDebugCapture ? 'Synthetic Audio' : 'Audio Waveform',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: isDebugCapture ? Colors.orange.shade600 : AppColors.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text(
              '$currentLevel',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: isAboveThreshold ? AppColors.warning : AppColors.muted,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
            Text(
              ' / $threshold',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          height: 60,
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
          ),
          clipBehavior: Clip.antiAlias,
          child: CustomPaint(
            painter: WaveformPainter(
              levels: levelHistory,
              threshold: threshold,
              primaryColor: AppColors.primary,
              warningColor: AppColors.warning,
            ),
            size: Size.infinite,
          ),
        ),
      ],
    );
  }
}

/// Custom painter for the waveform bars.
class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.levels,
    required this.threshold,
    required this.primaryColor,
    required this.warningColor,
  });

  final List<int> levels;
  final int threshold;
  final Color primaryColor;
  final Color warningColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;

    final thresholdY = size.height * (1 - threshold / 100.0);

    // Draw threshold line
    final thresholdPaint = Paint()
      ..color = Colors.red.withValues(alpha: 0.4)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(0, thresholdY),
      Offset(size.width, thresholdY),
      thresholdPaint,
    );

    // Calculate bar width based on number of samples to show
    const maxBars = 150; // Show up to 150 bars (~3 seconds)
    final samplesToShow = levels.length > maxBars ? maxBars : levels.length;
    final startIndex = levels.length > maxBars ? levels.length - maxBars : 0;
    final barWidth = size.width / maxBars;
    const barSpacing = 1.0;

    // Draw waveform bars
    for (var i = 0; i < samplesToShow; i++) {
      final level = levels[startIndex + i];
      final barHeight = (level / 100.0) * size.height;
      final x = i * barWidth;
      final y = size.height - barHeight;

      final isAboveThreshold = level >= threshold;
      final paint = Paint()
        ..color = isAboveThreshold
            ? warningColor.withValues(alpha: 0.8)
            : primaryColor.withValues(alpha: 0.7)
        ..style = PaintingStyle.fill;

      // Draw bar from bottom
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barWidth - barSpacing, barHeight),
        const Radius.circular(1),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) {
    return oldDelegate.levels != levels || oldDelegate.threshold != threshold;
  }
}
