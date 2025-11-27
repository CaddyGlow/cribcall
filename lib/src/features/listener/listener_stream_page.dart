import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../sound/audio_playback.dart';
import '../../theme.dart';
import '../../webrtc/webrtc_controller.dart';

// Conditional import for flutter_webrtc
import 'package:flutter_webrtc/flutter_webrtc.dart'
    if (dart.library.io) 'package:flutter_webrtc/flutter_webrtc.dart';

/// Check if WebRTC is supported on this platform.
bool get isWebRtcSupported {
  if (kIsWeb) return true;
  if (Platform.isAndroid || Platform.isIOS) return true;
  // Linux desktop supports WebRTC via flutter_webrtc
  if (Platform.isLinux) return true;
  // Other desktop platforms (Windows, macOS) - not tested yet
  return false;
}

/// Full-screen streaming page for listening to monitor audio/video.
class ListenerStreamPage extends ConsumerStatefulWidget {
  const ListenerStreamPage({
    super.key,
    this.monitorName,
    this.autoStart = false,
  });

  final String? monitorName;
  final bool autoStart;

  @override
  ConsumerState<ListenerStreamPage> createState() => _ListenerStreamPageState();
}

class _ListenerStreamPageState extends ConsumerState<ListenerStreamPage> {
  RTCVideoRenderer? _renderer;
  StreamSubscription<MediaStream?>? _streamSubscription;
  StreamSubscription<Uint8List>? _audioDataSubscription;
  AudioPlaybackService? _audioPlayback;
  bool _rendererInitialized = false;
  Timer? _pinTimer;

  @override
  void initState() {
    super.initState();
    if (isWebRtcSupported) {
      _initRenderer();
    }
    _initAudioPlayback();
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(streamingProvider.notifier).requestStream();
      });
    }
  }

  void _initAudioPlayback() {
    debugPrint('[listener_stream] _initAudioPlayback: subscribing to audioDataStream');
    // Subscribe to audio data from data channel
    _audioDataSubscription = ref
        .read(streamingProvider.notifier)
        .audioDataStream
        .listen(_onAudioData);
  }

  int _audioPacketCount = 0;
  bool _startingPlayback = false;

  void _onAudioData(Uint8List data) {
    _audioPacketCount++;
    if (_audioPacketCount == 1 || _audioPacketCount % 100 == 0) {
      debugPrint('[listener_stream] _onAudioData #$_audioPacketCount (${data.length} bytes, isRunning=${_audioPlayback?.isRunning}, starting=$_startingPlayback)');
    }
    // Start audio playback on first data if not already started or if stopped
    if (_audioPlayback == null || (!_audioPlayback!.isRunning && !_startingPlayback)) {
      debugPrint('[listener_stream] Starting AudioPlaybackService (was ${_audioPlayback == null ? "null" : "stopped"})');
      _audioPlayback ??= AudioPlaybackService();
      _startingPlayback = true;
      _audioPlayback!.start().then((success) {
        _startingPlayback = false;
        debugPrint('[listener_stream] AudioPlaybackService started: $success');
      });
    }
    _audioPlayback?.write(data);
  }

  Future<void> _initRenderer() async {
    if (!isWebRtcSupported) return;

    _renderer = RTCVideoRenderer();
    await _renderer!.initialize();
    setState(() => _rendererInitialized = true);

    // Subscribe to stream updates
    _streamSubscription = ref
        .read(streamingProvider.notifier)
        .remoteStreamUpdates
        .listen((stream) {
      if (mounted && _renderer != null) {
        setState(() {
          _renderer!.srcObject = stream;
        });
      }
    });

    // Check if there's already a stream
    final currentStream = ref.read(streamingProvider.notifier).remoteStream;
    if (currentStream != null && _renderer != null) {
      _renderer!.srcObject = currentStream;
    }
  }

  void _startPinTimer() {
    _pinTimer?.cancel();
    // Pin every 30 seconds to keep stream alive
    _pinTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      ref.read(streamingProvider.notifier).pinStream();
    });
  }

  void _stopPinTimer() {
    _pinTimer?.cancel();
    _pinTimer = null;
  }

  @override
  void dispose() {
    _stopPinTimer();
    _streamSubscription?.cancel();
    _audioDataSubscription?.cancel();
    _audioPlayback?.stop();
    _renderer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final streamState = ref.watch(streamingProvider);
    final isConnected = streamState.status == StreamingStatus.connected;

    // Start pin timer when connected
    if (isConnected && _pinTimer == null) {
      _startPinTimer();
    } else if (!isConnected) {
      _stopPinTimer();
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.monitorName ?? streamState.monitorName ?? 'Live Stream',
        ),
        actions: [
          if (isConnected)
            IconButton(
              onPressed: () => ref.read(streamingProvider.notifier).pinStream(),
              icon: const Icon(Icons.push_pin),
              tooltip: 'Keep stream alive',
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: _buildStreamContent(streamState),
              ),
            ),
            _buildControls(streamState),
          ],
        ),
      ),
    );
  }

  Widget _buildStreamContent(StreamingState state) {
    switch (state.status) {
      case StreamingStatus.idle:
        return _buildIdleState();

      case StreamingStatus.connecting:
        return _buildConnectingState();

      case StreamingStatus.connected:
        return _buildConnectedState();

      case StreamingStatus.disconnected:
        return _buildDisconnectedState();

      case StreamingStatus.error:
        return _buildErrorState(state.error ?? 'Unknown error');
    }
  }

  Widget _buildIdleState() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.headphones,
          size: 80,
          color: Colors.white.withValues(alpha: 0.5),
        ),
        const SizedBox(height: 24),
        Text(
          'Ready to stream',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Tap play to start listening',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Colors.white70,
          ),
        ),
      ],
    );
  }

  Widget _buildConnectingState() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 60,
          height: 60,
          child: CircularProgressIndicator(
            color: AppColors.primary,
            strokeWidth: 3,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'Connecting...',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Setting up secure stream',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Colors.white70,
          ),
        ),
      ],
    );
  }

  Widget _buildConnectedState() {
    if (!_rendererInitialized || _renderer == null) {
      return const CircularProgressIndicator(color: AppColors.primary);
    }

    final renderer = _renderer!;
    final hasVideo = renderer.srcObject?.getVideoTracks().isNotEmpty == true;

    if (hasVideo) {
      return RTCVideoView(
        renderer,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      );
    }

    // Audio-only visualization
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primary.withValues(alpha: 0.2),
          ),
          child: const Icon(
            Icons.graphic_eq,
            size: 60,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'Listening...',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.success,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Live',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.success,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDisconnectedState() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.cloud_off,
          size: 80,
          color: Colors.white.withValues(alpha: 0.5),
        ),
        const SizedBox(height: 24),
        Text(
          'Stream ended',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'The monitor ended the stream',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Colors.white70,
          ),
        ),
      ],
    );
  }

  Widget _buildErrorState(String error) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.error_outline,
          size: 80,
          color: Colors.red.withValues(alpha: 0.7),
        ),
        const SizedBox(height: 24),
        Text(
          'Connection error',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            error,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.white70,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildControls(StreamingState state) {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Back/Close button
          _ControlButton(
            icon: Icons.close,
            label: 'Close',
            onPressed: () {
              if (state.status == StreamingStatus.connected ||
                  state.status == StreamingStatus.connecting) {
                ref.read(streamingProvider.notifier).endStream();
              }
              Navigator.of(context).pop();
            },
          ),

          // Play/Stop button
          if (state.status == StreamingStatus.idle ||
              state.status == StreamingStatus.disconnected ||
              state.status == StreamingStatus.error)
            _ControlButton(
              icon: Icons.play_arrow,
              label: 'Play',
              isPrimary: true,
              onPressed: () {
                ref.read(streamingProvider.notifier).requestStream();
              },
            )
          else if (state.status == StreamingStatus.connected)
            _ControlButton(
              icon: Icons.stop,
              label: 'Stop',
              isPrimary: true,
              onPressed: () {
                ref.read(streamingProvider.notifier).endStream();
              },
            )
          else
            _ControlButton(
              icon: Icons.hourglass_empty,
              label: 'Wait',
              isPrimary: true,
              onPressed: null,
            ),

          // Video toggle (future feature)
          _ControlButton(
            icon: Icons.videocam_off,
            label: 'Video',
            onPressed: null, // Not yet implemented
          ),
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    this.onPressed,
    this.isPrimary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final bgColor = isPrimary
        ? (enabled ? AppColors.primary : AppColors.primary.withValues(alpha: 0.3))
        : Colors.white.withValues(alpha: enabled ? 0.1 : 0.05);
    final fgColor = enabled ? Colors.white : Colors.white38;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: bgColor,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: Container(
              width: isPrimary ? 72 : 56,
              height: isPrimary ? 72 : 56,
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: isPrimary ? 36 : 28,
                color: fgColor,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            color: fgColor,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
