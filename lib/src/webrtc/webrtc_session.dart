import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'webrtc_config.dart';

/// Callback for ICE candidates to send to remote peer.
typedef OnIceCandidate = void Function(Map<String, dynamic> candidate);

/// Callback when remote stream is received.
typedef OnRemoteStream = void Function(MediaStream stream);

/// Callback when connection state changes.
typedef OnConnectionState = void Function(RTCPeerConnectionState state);

/// Callback when audio data is received via data channel.
typedef OnAudioData = void Function(Uint8List data);

/// WebRTC session for receiving audio/video stream from monitor.
/// This is the Listener-side implementation.
class WebRtcSession {
  WebRtcSession({
    required this.sessionId,
    required this.onIceCandidate,
    required this.onRemoteStream,
    this.onConnectionState,
    this.onAudioData,
    WebRtcConfig? config,
  }) : _config = config ?? const WebRtcConfig();

  final String sessionId;
  final OnIceCandidate onIceCandidate;
  final OnRemoteStream onRemoteStream;
  final OnConnectionState? onConnectionState;
  final OnAudioData? onAudioData;
  final WebRtcConfig _config;

  RTCPeerConnection? _peerConnection;
  MediaStream? _remoteStream;
  RTCDataChannel? _audioDataChannel;
  bool _disposed = false;

  /// Whether this session has been disposed.
  bool get isDisposed => _disposed;

  /// Current remote stream (if any).
  MediaStream? get remoteStream => _remoteStream;

  /// Whether receiving audio via data channel (instead of media track).
  bool get usesDataChannelAudio => _audioDataChannel != null;

  /// Initialize the peer connection.
  Future<void> initialize() async {
    if (_disposed) return;

    _log('Initializing WebRTC session');

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

    _peerConnection!.onTrack = (event) {
      _log('Track received: ${event.track.kind}');
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        onRemoteStream(_remoteStream!);
      }
    };

    _peerConnection!.onAddStream = (stream) {
      _log('Stream added');
      _remoteStream = stream;
      onRemoteStream(stream);
    };

    // Handle incoming data channel (for Android audio streaming)
    _peerConnection!.onDataChannel = (channel) {
      _log('Data channel received: ${channel.label}');
      if (channel.label == 'audio') {
        _audioDataChannel = channel;
        _setupAudioDataChannel();
      }
    };

    _log('WebRTC session initialized');
  }

  int _receivedPackets = 0;

  /// Set up audio data channel message handling.
  void _setupAudioDataChannel() {
    if (_audioDataChannel == null) return;

    _audioDataChannel!.onDataChannelState = (state) {
      _log('Audio data channel state: $state');
    };

    _audioDataChannel!.onMessage = (message) {
      if (_disposed) return;
      if (message.isBinary) {
        _receivedPackets++;
        if (_receivedPackets == 1 || _receivedPackets % 100 == 0) {
          _log('Received audio packet #$_receivedPackets (${message.binary.length} bytes), onAudioData=${onAudioData != null}');
        }
        if (onAudioData != null) {
          onAudioData!(message.binary);
        } else if (_receivedPackets == 1) {
          _log('WARNING: onAudioData callback is null, audio will not be forwarded');
        }
      }
    };

    _log('Audio data channel set up');
  }

  /// Handle incoming SDP offer from monitor.
  /// Returns the SDP answer to send back.
  Future<String> handleOffer(String sdp) async {
    if (_disposed || _peerConnection == null) {
      throw StateError('Session not initialized or disposed');
    }

    _log('Setting remote description (offer)');

    final offer = RTCSessionDescription(sdp, 'offer');
    await _peerConnection!.setRemoteDescription(offer);

    _log('Creating answer');
    final answer = await _peerConnection!.createAnswer();

    _log('Setting local description (answer)');
    await _peerConnection!.setLocalDescription(answer);

    return answer.sdp!;
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

    _log('Disposing WebRTC session');

    // Close audio data channel
    try {
      await _audioDataChannel?.close();
    } catch (e) {
      _log('Error closing audio data channel: $e');
    }
    _audioDataChannel = null;

    try {
      await _remoteStream?.dispose();
    } catch (e) {
      _log('Error disposing remote stream: $e');
    }
    _remoteStream = null;

    try {
      await _peerConnection?.close();
    } catch (e) {
      _log('Error closing peer connection: $e');
    }
    _peerConnection = null;

    _log('WebRTC session disposed');
  }

  void _log(String message) {
    developer.log('[$sessionId] $message', name: 'webrtc_session');
    debugPrint('[webrtc_session] [$sessionId] $message');
  }
}
