import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../control/control_messages.dart';
import '../state/app_state.dart';
import 'monitor_webrtc_session.dart';

/// State for a single streaming session.
class MonitorStreamSession {
  const MonitorStreamSession({
    required this.sessionId,
    required this.connectionId,
    required this.mediaType,
    this.status = MonitorStreamStatus.starting,
  });

  final String sessionId;
  final String connectionId;
  final String mediaType;
  final MonitorStreamStatus status;

  MonitorStreamSession copyWith({MonitorStreamStatus? status}) {
    return MonitorStreamSession(
      sessionId: sessionId,
      connectionId: connectionId,
      mediaType: mediaType,
      status: status ?? this.status,
    );
  }
}

enum MonitorStreamStatus {
  starting,
  connecting,
  streaming,
  ended,
  error,
}

/// State for the monitor streaming controller.
class MonitorStreamingState {
  const MonitorStreamingState({
    this.activeSessions = const {},
  });

  /// Map of sessionId -> session info
  final Map<String, MonitorStreamSession> activeSessions;

  MonitorStreamingState copyWith({
    Map<String, MonitorStreamSession>? activeSessions,
  }) {
    return MonitorStreamingState(
      activeSessions: activeSessions ?? this.activeSessions,
    );
  }

  bool hasSession(String sessionId) => activeSessions.containsKey(sessionId);
  MonitorStreamSession? getSession(String sessionId) => activeSessions[sessionId];
}

/// Callback to send messages to a specific connection.
typedef SendToConnection = Future<void> Function(
    String connectionId, ControlMessage message);

/// Controller for managing WebRTC streaming sessions on the monitor side.
class MonitorStreamingController extends Notifier<MonitorStreamingState> {
  final Map<String, MonitorWebRtcSession> _webrtcSessions = {};
  SendToConnection? _sendToConnection;

  @override
  MonitorStreamingState build() {
    ref.onDispose(_cleanup);
    return const MonitorStreamingState();
  }

  /// Set the callback for sending messages to connections.
  void setSendCallback(SendToConnection callback) {
    _sendToConnection = callback;
  }

  /// Handle incoming stream request from a listener.
  Future<void> handleStreamRequest({
    required String sessionId,
    required String connectionId,
    required String mediaType,
  }) async {
    _log('Stream request: session=$sessionId connection=$connectionId media=$mediaType');

    if (state.hasSession(sessionId)) {
      _log('Session already exists: $sessionId');
      await _sendResponse(connectionId, sessionId, false, 'Session already exists');
      return;
    }

    // Create session entry
    final session = MonitorStreamSession(
      sessionId: sessionId,
      connectionId: connectionId,
      mediaType: mediaType,
      status: MonitorStreamStatus.starting,
    );

    state = state.copyWith(
      activeSessions: {...state.activeSessions, sessionId: session},
    );

    // Send acceptance response
    await _sendResponse(connectionId, sessionId, true, null);

    // Create WebRTC session
    try {
      await _createWebRtcSession(sessionId, connectionId, mediaType);
    } catch (e) {
      _log('Error creating WebRTC session: $e');
      await _endSession(sessionId, 'WebRTC initialization failed: $e');
    }
  }

  Future<void> _createWebRtcSession(
    String sessionId,
    String connectionId,
    String mediaType,
  ) async {
    _log('Creating WebRTC session: $sessionId');

    // Get audio data provider from AudioCaptureController (for Android data channel mode)
    // This is called when peer connection reaches connected state, so audio capture
    // should be running by then. If not available yet, poll until it is.
    Stream<Uint8List> audioDataProvider() {
      return _getAudioStream();
    }

    final webrtcSession = MonitorWebRtcSession(
      sessionId: sessionId,
      mediaType: mediaType,
      onIceCandidate: (candidate) => _sendIceCandidate(connectionId, sessionId, candidate),
      onConnectionState: (state) => _onConnectionState(sessionId, state),
      audioDataProvider: audioDataProvider,
    );

    _webrtcSessions[sessionId] = webrtcSession;

    // Initialize and capture media
    await webrtcSession.initialize();

    // Update status to connecting
    _updateSessionStatus(sessionId, MonitorStreamStatus.connecting);

    // Create and send offer
    final sdp = await webrtcSession.createOffer();
    await _sendOffer(connectionId, sessionId, sdp);

    _log('WebRTC offer sent for session: $sessionId');
  }

  void _onConnectionState(String sessionId, RTCPeerConnectionState state) {
    _log('Connection state for $sessionId: $state');

    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _updateSessionStatus(sessionId, MonitorStreamStatus.streaming);
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        _endSession(sessionId, null);
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _endSession(sessionId, 'Connection failed');
      default:
        break;
    }
  }

  /// Handle incoming WebRTC answer from listener.
  Future<void> handleAnswer({
    required String sessionId,
    required String sdp,
  }) async {
    _log('Received answer for session: $sessionId');

    final webrtcSession = _webrtcSessions[sessionId];
    if (webrtcSession == null) {
      _log('No WebRTC session found for: $sessionId');
      return;
    }

    try {
      await webrtcSession.handleAnswer(sdp);
      _log('Answer processed for session: $sessionId');
    } catch (e) {
      _log('Error handling answer: $e');
      await _endSession(sessionId, 'Error processing answer: $e');
    }
  }

  /// Handle incoming ICE candidate from listener.
  Future<void> handleIceCandidate({
    required String sessionId,
    required Map<String, dynamic> candidate,
  }) async {
    final webrtcSession = _webrtcSessions[sessionId];
    if (webrtcSession == null) {
      _log('No WebRTC session found for ICE: $sessionId');
      return;
    }

    try {
      await webrtcSession.addIceCandidate(candidate);
    } catch (e) {
      _log('Error adding ICE candidate: $e');
    }
  }

  /// Handle end stream request from listener.
  Future<void> handleEndStream({required String sessionId}) async {
    _log('End stream request: $sessionId');
    await _endSession(sessionId, null);
  }

  /// End a streaming session.
  Future<void> _endSession(String sessionId, String? error) async {
    _log('Ending session: $sessionId error=$error');

    final session = state.getSession(sessionId);
    if (session == null) return;

    // Dispose WebRTC session
    final webrtcSession = _webrtcSessions.remove(sessionId);
    await webrtcSession?.dispose();

    // Send end stream message
    await _sendEndStream(session.connectionId, sessionId);

    // Update state
    final sessions = Map<String, MonitorStreamSession>.from(state.activeSessions);
    sessions.remove(sessionId);
    state = state.copyWith(activeSessions: sessions);
  }

  /// End all sessions for a specific connection (when client disconnects).
  Future<void> endSessionsForConnection(String connectionId) async {
    final sessionsToEnd = state.activeSessions.values
        .where((s) => s.connectionId == connectionId)
        .map((s) => s.sessionId)
        .toList();

    for (final sessionId in sessionsToEnd) {
      await _endSession(sessionId, 'Client disconnected');
    }
  }

  void _updateSessionStatus(String sessionId, MonitorStreamStatus status) {
    final session = state.getSession(sessionId);
    if (session == null) return;

    state = state.copyWith(
      activeSessions: {
        ...state.activeSessions,
        sessionId: session.copyWith(status: status),
      },
    );
  }

  // Message sending helpers

  Future<void> _sendResponse(
    String connectionId,
    String sessionId,
    bool accepted,
    String? reason,
  ) async {
    final message = StartStreamResponseMessage(
      sessionId: sessionId,
      accepted: accepted,
      reason: reason,
    );
    await _sendToConnection?.call(connectionId, message);
  }

  Future<void> _sendOffer(
    String connectionId,
    String sessionId,
    String sdp,
  ) async {
    final message = WebRtcOfferMessage(sessionId: sessionId, sdp: sdp);
    await _sendToConnection?.call(connectionId, message);
  }

  Future<void> _sendIceCandidate(
    String connectionId,
    String sessionId,
    Map<String, dynamic> candidate,
  ) async {
    final message = WebRtcIceMessage(sessionId: sessionId, candidate: candidate);
    await _sendToConnection?.call(connectionId, message);
  }

  Future<void> _sendEndStream(String connectionId, String sessionId) async {
    final message = EndStreamMessage(sessionId: sessionId);
    await _sendToConnection?.call(connectionId, message);
  }

  Future<void> _cleanup() async {
    _log('Cleaning up monitor streaming controller');
    for (final sessionId in _webrtcSessions.keys.toList()) {
      await _endSession(sessionId, 'Controller disposed');
    }
    _webrtcSessions.clear();
  }

  void _log(String message) {
    developer.log(message, name: 'monitor_streaming');
    debugPrint('[monitor_streaming] $message');
  }

  /// Get audio stream from AudioCaptureController with auto-reconnect.
  /// This handles:
  /// 1. Race condition where WebRTC session is created before audio capture starts
  /// 2. Audio capture restarts (which create new stream instances)
  Stream<Uint8List> _getAudioStream() {
    _log('_getAudioStream: creating resilient audio stream');
    return _createResilientAudioStream();
  }

  /// Create a stream that automatically reconnects to the audio capture stream.
  /// This handles audio capture restarts by re-fetching the stream when it ends.
  Stream<Uint8List> _createResilientAudioStream() async* {
    int reconnectCount = 0;
    const maxReconnects = 100; // Allow many reconnects over session lifetime

    while (reconnectCount < maxReconnects) {
      final audioCapture = ref.read(audioCaptureProvider.notifier);
      var stream = audioCapture.rawAudioStream;

      // Poll for stream if not immediately available
      if (stream == null) {
        _log('_createResilientAudioStream: waiting for stream (attempt ${reconnectCount + 1})');
        for (var i = 0; i < 50; i++) {
          await Future.delayed(const Duration(milliseconds: 100));
          stream = ref.read(audioCaptureProvider.notifier).rawAudioStream;
          if (stream != null) {
            _log('_createResilientAudioStream: stream available after ${i * 100}ms');
            break;
          }
        }
        if (stream == null) {
          _log('_createResilientAudioStream: stream not available after 5s, retrying...');
          reconnectCount++;
          continue;
        }
      }

      // Yield from the stream until it ends
      _log('_createResilientAudioStream: connected to audio stream');
      int packetCount = 0;
      await for (final data in stream) {
        packetCount++;
        if (packetCount == 1 || packetCount % 500 == 0) {
          _log('_createResilientAudioStream: forwarded $packetCount packets');
        }
        yield data;
      }

      // Stream ended - this happens when audio capture restarts
      _log('_createResilientAudioStream: stream ended after $packetCount packets, reconnecting...');
      reconnectCount++;

      // Small delay before reconnecting to avoid tight loop
      await Future.delayed(const Duration(milliseconds: 100));
    }

    _log('_createResilientAudioStream: max reconnects reached');
  }
}

/// Provider for the monitor streaming controller.
final monitorStreamingProvider =
    NotifierProvider<MonitorStreamingController, MonitorStreamingState>(
  MonitorStreamingController.new,
);
