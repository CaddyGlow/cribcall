import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../utils/logger.dart';
import 'control_frame_codec.dart';
import 'control_messages.dart';

/// WebSocket connection wrapper for control messages.
class ControlConnection {
  ControlConnection({
    required this.socket,
    required this.peerFingerprint,
    required this.connectionId,
    required this.remoteHost,
    required this.remotePort,
  }) {
    _log('Connection established: $connectionId peer=${_shortFp(peerFingerprint)}');
    _subscription = socket.listen(
      _handleData,
      onError: (error, stack) {
        _log('Socket error on $connectionId: $error');
        _messagesController.addError(error);
        _close();
      },
      onDone: _close,
    );
  }

  final WebSocket socket;
  final String peerFingerprint;
  final String connectionId;
  final String remoteHost;
  final int remotePort;

  final ControlFrameDecoder _decoder = ControlFrameDecoder();
  final _messagesController = StreamController<ControlMessage>.broadcast();
  StreamSubscription? _subscription;
  bool _closed = false;

  /// Stream of incoming control messages.
  Stream<ControlMessage> get messages => _messagesController.stream;

  /// Whether the connection is closed.
  bool get isClosed => _closed;

  /// Remote address as "host:port".
  String get remoteAddress => '$remoteHost:$remotePort';

  void _handleData(dynamic data) {
    if (_closed) return;

    final bytes = switch (data) {
      List<int> value => Uint8List.fromList(value),
      String text => Uint8List.fromList(utf8.encode(text)),
      _ => null,
    };
    if (bytes == null) return;

    try {
      final frames = _decoder.addChunkAndDecodeJson(bytes);
      for (final frame in frames) {
        final message = ControlMessageFactory.fromWireJson(frame);
        _log('Received ${message.type.name} on $connectionId');
        _messagesController.add(message);
      }
    } catch (e) {
      _log('Frame decode error on $connectionId: $e');
      _messagesController.addError(e);
      unawaited(close());
    }
  }

  /// Send a control message.
  Future<void> send(ControlMessage message) async {
    if (_closed) {
      throw StateError('Connection is closed');
    }
    final frame = ControlFrameCodec.encodeJson(message.toWireJson());
    _log('Sending ${message.type.name} on $connectionId');
    socket.add(frame);
  }

  /// Close the connection.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _log('Closing connection $connectionId');
    try {
      await socket.close();
    } catch (_) {}
    await _subscription?.cancel();
    await _messagesController.close();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _log('Connection closed: $connectionId');
    _subscription?.cancel();
    _messagesController.close();
  }
}

const _log = Logger('control_conn');

String _shortFp(String fp) {
  if (fp.length <= 12) return fp;
  return fp.substring(0, 12);
}
