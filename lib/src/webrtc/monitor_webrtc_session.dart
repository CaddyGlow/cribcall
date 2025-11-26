import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'webrtc_config.dart';

/// Callback for ICE candidates to send to remote peer.
typedef OnIceCandidate = void Function(Map<String, dynamic> candidate);

/// Callback when connection state changes.
typedef OnConnectionState = void Function(RTCPeerConnectionState state);

/// WebRTC session for streaming audio/video from monitor to listener.
/// This is the Monitor-side implementation (creates offer, captures local media).
class MonitorWebRtcSession {
  MonitorWebRtcSession({
    required this.sessionId,
    required this.onIceCandidate,
    this.onConnectionState,
    this.mediaType = 'audio',
    WebRtcConfig? config,
  }) : _config = config ?? const WebRtcConfig();

  final String sessionId;
  final OnIceCandidate onIceCandidate;
  final OnConnectionState? onConnectionState;
  final String mediaType;
  final WebRtcConfig _config;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  bool _disposed = false;

  /// Whether this session has been disposed.
  bool get isDisposed => _disposed;

  /// Current local stream (if any).
  MediaStream? get localStream => _localStream;

  /// Initialize the peer connection and capture local media.
  Future<void> initialize() async {
    if (_disposed) return;

    _log('Initializing monitor WebRTC session');

    final configuration = {
      'iceServers': _config.iceServers.isEmpty
          ? [
              // LAN-only: empty ice servers for host candidates only
            ]
          : _config.iceServers,
      'sdpSemantics': 'unified-plan',
    };

    _peerConnection = await createPeerConnection(configuration);

    _peerConnection!.onIceCandidate = (candidate) {
      if (_disposed || candidate.candidate == null) return;
      _log('ICE candidate: ${candidate.candidate}');
      onIceCandidate({
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _peerConnection!.onIceConnectionState = (state) {
      _log('ICE connection state: $state');
    };

    _peerConnection!.onConnectionState = (state) {
      _log('Connection state: $state');
      onConnectionState?.call(state);
    };

    // Capture local media
    await _captureLocalMedia();

    _log('Monitor WebRTC session initialized');
  }

  Future<void> _captureLocalMedia() async {
    _log('Capturing local media: $mediaType');

    final constraints = <String, dynamic>{
      'audio': mediaType.contains('audio')
          ? {
              'echoCancellation': true,
              'noiseSuppression': true,
              'autoGainControl': true,
            }
          : false,
      'video': mediaType.contains('video')
          ? {
              'facingMode': 'environment',
              'width': {'ideal': 640},
              'height': {'ideal': 480},
              'frameRate': {'ideal': 15},
            }
          : false,
    };

    try {
      _localStream = await navigator.mediaDevices.getUserMedia(constraints);
      _log('Local stream captured: ${_localStream!.id}');

      // Add tracks to peer connection
      for (final track in _localStream!.getTracks()) {
        _log('Adding track: ${track.kind}');
        await _peerConnection!.addTrack(track, _localStream!);
      }
    } catch (e) {
      _log('Error capturing local media: $e');
      rethrow;
    }
  }

  /// Create and return an SDP offer to send to the listener.
  Future<String> createOffer() async {
    if (_disposed || _peerConnection == null) {
      throw StateError('Session not initialized or disposed');
    }

    _log('Creating offer');
    final offer = await _peerConnection!.createOffer();

    _log('Setting local description (offer)');
    await _peerConnection!.setLocalDescription(offer);

    return offer.sdp!;
  }

  /// Handle incoming SDP answer from listener.
  Future<void> handleAnswer(String sdp) async {
    if (_disposed || _peerConnection == null) {
      throw StateError('Session not initialized or disposed');
    }

    _log('Setting remote description (answer)');
    final answer = RTCSessionDescription(sdp, 'answer');
    await _peerConnection!.setRemoteDescription(answer);
  }

  /// Add ICE candidate from remote peer.
  Future<void> addIceCandidate(Map<String, dynamic> candidateMap) async {
    if (_disposed || _peerConnection == null) return;

    final candidate = RTCIceCandidate(
      candidateMap['candidate'] as String?,
      candidateMap['sdpMid'] as String?,
      candidateMap['sdpMLineIndex'] as int?,
    );

    _log('Adding ICE candidate');
    await _peerConnection!.addCandidate(candidate);
  }

  /// Dispose of this session and clean up resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    _log('Disposing monitor WebRTC session');

    try {
      // Stop all tracks
      for (final track in _localStream?.getTracks() ?? []) {
        await track.stop();
      }
      await _localStream?.dispose();
    } catch (e) {
      _log('Error disposing local stream: $e');
    }
    _localStream = null;

    try {
      await _peerConnection?.close();
    } catch (e) {
      _log('Error closing peer connection: $e');
    }
    _peerConnection = null;

    _log('Monitor WebRTC session disposed');
  }

  void _log(String message) {
    developer.log('[$sessionId] $message', name: 'monitor_webrtc');
    debugPrint('[monitor_webrtc] [$sessionId] $message');
  }
}
