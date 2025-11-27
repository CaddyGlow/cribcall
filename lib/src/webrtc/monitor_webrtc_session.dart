import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'webrtc_config.dart';

/// Callback for ICE candidates to send to remote peer.
typedef OnIceCandidate = void Function(Map<String, dynamic> candidate);

/// Callback when connection state changes.
typedef OnConnectionState = void Function(RTCPeerConnectionState state);

/// Callback to provide audio data for streaming.
typedef AudioDataProvider = Stream<Uint8List> Function();

/// WebRTC session for streaming audio/video from monitor to listener.
/// This is the Monitor-side implementation (creates offer, captures local media).
///
/// On Android, uses data channel to stream audio from the foreground service
/// instead of getUserMedia to avoid mic conflicts.
class MonitorWebRtcSession {
  MonitorWebRtcSession({
    required this.sessionId,
    required this.onIceCandidate,
    this.onConnectionState,
    this.mediaType = 'audio',
    this.audioDataProvider,
    WebRtcConfig? config,
  }) : _config = config ?? const WebRtcConfig();

  final String sessionId;
  final OnIceCandidate onIceCandidate;
  final OnConnectionState? onConnectionState;
  final String mediaType;
  final WebRtcConfig _config;

  /// Provider for audio data (used on Android to get data from AudioCaptureService).
  final AudioDataProvider? audioDataProvider;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  RTCDataChannel? _audioDataChannel;
  StreamSubscription<Uint8List>? _audioSubscription;
  bool _disposed = false;

  /// Whether this session has been disposed.
  bool get isDisposed => _disposed;

  /// Current local stream (if any).
  MediaStream? get localStream => _localStream;

  /// Whether using data channel for audio (Android).
  bool get usesDataChannelAudio => !kIsWeb && Platform.isAndroid && audioDataProvider != null;

  /// Initialize the peer connection and capture local media.
  Future<void> initialize() async {
    if (_disposed) return;

    _log('Initializing monitor WebRTC session (dataChannel=$usesDataChannelAudio)');

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

      // Start sending audio data when connected (for data channel mode)
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
          usesDataChannelAudio) {
        _startAudioDataStream();
      }
    };

    // On Android with audio provider, use data channel instead of getUserMedia
    if (usesDataChannelAudio) {
      await _createAudioDataChannel();
    } else {
      // Capture local media using getUserMedia (non-Android or no provider)
      await _captureLocalMedia();
    }

    _log('Monitor WebRTC session initialized');
  }

  /// Create a data channel for streaming audio (Android).
  Future<void> _createAudioDataChannel() async {
    _log('Creating audio data channel');

    final channelInit = RTCDataChannelInit()
      ..ordered = true
      ..maxRetransmits = 0; // Unreliable for low latency

    _audioDataChannel = await _peerConnection!.createDataChannel(
      'audio',
      channelInit,
    );

    _audioDataChannel!.onDataChannelState = (state) {
      _log('Audio data channel state: $state');
    };

    _log('Audio data channel created');
  }

  /// Start streaming audio data through the data channel.
  void _startAudioDataStream() {
    if (_audioDataChannel == null || audioDataProvider == null) {
      _log('Cannot start audio stream: channel=${_audioDataChannel != null}, provider=${audioDataProvider != null}');
      return;
    }

    _log('Starting audio data stream');

    int packetCount = 0;
    _audioSubscription?.cancel();
    _audioSubscription = audioDataProvider!().listen(
      (data) {
        if (_disposed || _audioDataChannel == null) return;
        try {
          _audioDataChannel!.send(RTCDataChannelMessage.fromBinary(data));
          packetCount++;
          if (packetCount == 1 || packetCount % 100 == 0) {
            _log('Sent audio packet #$packetCount (${data.length} bytes)');
          }
        } catch (e) {
          _log('Error sending audio data: $e');
        }
      },
      onError: (e) => _log('Audio data stream error: $e'),
      onDone: () => _log('Audio data stream ended (sent $packetCount packets)'),
    );
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

    // Stop audio data subscription
    await _audioSubscription?.cancel();
    _audioSubscription = null;

    // Close audio data channel
    try {
      await _audioDataChannel?.close();
    } catch (e) {
      _log('Error closing audio data channel: $e');
    }
    _audioDataChannel = null;

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
