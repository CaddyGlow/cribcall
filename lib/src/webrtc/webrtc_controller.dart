import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../control/control_messages.dart';
import '../control/control_service.dart';
import '../state/app_state.dart';
import 'webrtc_session.dart';

/// State of the WebRTC streaming session.
enum StreamingStatus {
  idle,
  connecting,
  connected,
  disconnected,
  error,
}

/// State for the WebRTC streaming controller.
class StreamingState {
  const StreamingState({
    this.status = StreamingStatus.idle,
    this.sessionId,
    this.monitorName,
    this.error,
  });

  final StreamingStatus status;
  final String? sessionId;
  final String? monitorName;
  final String? error;

  StreamingState copyWith({
    StreamingStatus? status,
    String? sessionId,
    String? monitorName,
    String? error,
  }) {
    return StreamingState(
      status: status ?? this.status,
      sessionId: sessionId ?? this.sessionId,
      monitorName: monitorName ?? this.monitorName,
      error: error,
    );
  }
}

/// Controller for WebRTC streaming.
/// Manages the peer connection and coordinates with the control client.
class StreamingController extends Notifier<StreamingState> {
  WebRtcSession? _session;
  StreamSubscription<ControlMessage>? _signalingSubscription;
  MediaStream? _remoteStream;

  /// Current remote media stream for playback.
  MediaStream? get remoteStream => _remoteStream;

  /// Stream of remote media stream updates.
  final _remoteStreamController = StreamController<MediaStream?>.broadcast();
  Stream<MediaStream?> get remoteStreamUpdates => _remoteStreamController.stream;

  @override
  StreamingState build() {
    ref.onDispose(_cleanup);
    _subscribeToSignaling();
    return const StreamingState();
  }

  void _subscribeToSignaling() {
    final controlClient = ref.read(controlClientProvider.notifier);
    _signalingSubscription?.cancel();
    _signalingSubscription = controlClient.webrtcSignaling.listen(
      _handleSignalingMessage,
      onError: (e) => _log('Signaling error: $e'),
    );
  }

  void _handleSignalingMessage(ControlMessage message) {
    _log('Signaling message: ${message.type.name}');

    switch (message) {
      case StartStreamResponseMessage(:final sessionId, :final accepted, :final reason):
        _handleStreamResponse(sessionId, accepted, reason);

      case WebRtcOfferMessage(:final sessionId, :final sdp):
        _handleOffer(sessionId, sdp);

      case WebRtcIceMessage(:final sessionId, :final candidate):
        _handleIceCandidate(sessionId, candidate);

      case EndStreamMessage(:final sessionId):
        _handleStreamEnded(sessionId);

      default:
        break;
    }
  }

  void _handleStreamResponse(String sessionId, bool accepted, String? reason) {
    if (!accepted) {
      _log('Stream request rejected: $reason');
      state = state.copyWith(
        status: StreamingStatus.error,
        error: reason ?? 'Stream request rejected',
      );
      return;
    }

    _log('Stream request accepted: $sessionId');
    state = state.copyWith(
      status: StreamingStatus.connecting,
      sessionId: sessionId,
    );
  }

  Future<void> _handleOffer(String sessionId, String sdp) async {
    if (state.sessionId != null && state.sessionId != sessionId) {
      _log('Ignoring offer for different session: $sessionId');
      return;
    }

    _log('Handling WebRTC offer');

    try {
      // Create session if not exists
      _session ??= WebRtcSession(
        sessionId: sessionId,
        onIceCandidate: _sendIceCandidate,
        onRemoteStream: _onRemoteStream,
        onConnectionState: _onConnectionState,
      );

      await _session!.initialize();
      final answerSdp = await _session!.handleOffer(sdp);

      // Send answer to monitor
      await ref.read(controlClientProvider.notifier).sendWebRtcAnswer(
        sessionId: sessionId,
        sdp: answerSdp,
      );

      state = state.copyWith(
        status: StreamingStatus.connecting,
        sessionId: sessionId,
      );
    } catch (e) {
      _log('Error handling offer: $e');
      state = state.copyWith(
        status: StreamingStatus.error,
        error: 'Failed to process WebRTC offer: $e',
      );
    }
  }

  Future<void> _handleIceCandidate(String sessionId, Map<String, dynamic> candidate) async {
    if (state.sessionId != sessionId || _session == null) {
      _log('Ignoring ICE candidate for different/no session');
      return;
    }

    try {
      await _session!.addIceCandidate(candidate);
    } catch (e) {
      _log('Error adding ICE candidate: $e');
    }
  }

  void _handleStreamEnded(String sessionId) {
    if (state.sessionId != sessionId) return;

    _log('Stream ended by monitor');
    _closeSession();
    state = const StreamingState(status: StreamingStatus.disconnected);
  }

  void _sendIceCandidate(Map<String, dynamic> candidate) {
    final sessionId = state.sessionId;
    if (sessionId == null) return;

    ref.read(controlClientProvider.notifier).sendWebRtcIce(
      sessionId: sessionId,
      candidate: candidate,
    );
  }

  void _onRemoteStream(MediaStream stream) {
    _log('Remote stream received');
    _remoteStream = stream;
    _remoteStreamController.add(stream);
    state = state.copyWith(status: StreamingStatus.connected);
  }

  void _onConnectionState(RTCPeerConnectionState connectionState) {
    _log('Peer connection state: $connectionState');

    switch (connectionState) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        state = state.copyWith(status: StreamingStatus.connected);
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        state = state.copyWith(status: StreamingStatus.disconnected);
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        state = state.copyWith(
          status: StreamingStatus.error,
          error: 'Connection failed',
        );
      default:
        break;
    }
  }

  /// Request a stream from the connected monitor.
  Future<void> requestStream({String mediaType = 'audio'}) async {
    final controlClient = ref.read(controlClientProvider);
    if (controlClient.status != ControlClientStatus.connected) {
      state = state.copyWith(
        status: StreamingStatus.error,
        error: 'Not connected to monitor',
      );
      return;
    }

    state = state.copyWith(
      status: StreamingStatus.connecting,
      monitorName: controlClient.monitorName,
    );

    try {
      final sessionId = await ref.read(controlClientProvider.notifier).requestStream(
        mediaType: mediaType,
      );
      state = state.copyWith(sessionId: sessionId);
    } catch (e) {
      _log('Error requesting stream: $e');
      state = state.copyWith(
        status: StreamingStatus.error,
        error: 'Failed to request stream: $e',
      );
    }
  }

  /// End the current streaming session.
  Future<void> endStream() async {
    final sessionId = state.sessionId;
    if (sessionId == null) return;

    _log('Ending stream');

    try {
      await ref.read(controlClientProvider.notifier).endStream(sessionId);
    } catch (e) {
      _log('Error ending stream: $e');
    }

    _closeSession();
    state = const StreamingState(status: StreamingStatus.idle);
  }

  /// Pin the current stream to keep it alive.
  Future<void> pinStream() async {
    final sessionId = state.sessionId;
    if (sessionId == null) return;

    try {
      await ref.read(controlClientProvider.notifier).pinStream(sessionId);
    } catch (e) {
      _log('Error pinning stream: $e');
    }
  }

  void _closeSession() {
    _session?.dispose();
    _session = null;
    _remoteStream = null;
    _remoteStreamController.add(null);
  }

  Future<void> _cleanup() async {
    _signalingSubscription?.cancel();
    _signalingSubscription = null;
    _closeSession();
    await _remoteStreamController.close();
  }

  void _log(String message) {
    developer.log(message, name: 'streaming_ctrl');
    debugPrint('[streaming_ctrl] $message');
  }
}

/// Provider for the streaming controller.
final streamingProvider = NotifierProvider<StreamingController, StreamingState>(
  StreamingController.new,
);
