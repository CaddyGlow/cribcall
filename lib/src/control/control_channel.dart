import 'dart:async';
import 'dart:collection';

import '../utils/logger.dart';
import 'control_message.dart';
import 'control_transport.dart';

enum ControlChannelStatus { connecting, connected, closed, error }

class ControlChannelState {
  const ControlChannelState._({
    required this.status,
    this.connectionId,
    this.peerFingerprint,
    this.failure,
  });

  const ControlChannelState.connecting()
    : this._(status: ControlChannelStatus.connecting);

  const ControlChannelState.connected({
    required String connectionId,
    required String peerFingerprint,
  }) : this._(
         status: ControlChannelStatus.connected,
         connectionId: connectionId,
         peerFingerprint: peerFingerprint,
       );

  const ControlChannelState.closed({
    String? connectionId,
    String? peerFingerprint,
  }) : this._(
         status: ControlChannelStatus.closed,
         connectionId: connectionId,
         peerFingerprint: peerFingerprint,
       );

  const ControlChannelState.error({
    String? connectionId,
    String? peerFingerprint,
    required ControlFailure failure,
  }) : this._(
         status: ControlChannelStatus.error,
         connectionId: connectionId,
         peerFingerprint: peerFingerprint,
         failure: failure,
       );

  final ControlChannelStatus status;
  final String? connectionId;
  final String? peerFingerprint;
  final ControlFailure? failure;
}

enum ControlFailureType {
  fingerprintMismatch,
  untrustedClient,
  protocolViolation,
  timeout,
  transport,
  closed,
  unknown,
}

class ControlFailure {
  const ControlFailure(this.type, this.message);

  final ControlFailureType type;
  final String message;
}

class ControlChannelClosedException implements Exception {
  ControlChannelClosedException(this.failure);

  final ControlFailure? failure;

  @override
  String toString() {
    if (failure == null) return 'ControlChannelClosed(connection closed)';
    return 'ControlChannelClosed(${failure!.type.name}: ${failure!.message})';
  }
}

/// Wraps a [ControlConnection] with connection state, send queueing,
/// and error mapping for the control channel.
class ControlChannel {
  ControlChannel({required ControlConnection connection})
    : _connection = connection {
    _state = const ControlChannelState.connecting();
    _stateController.add(_state);
    _log(
      'Initializing control channel to '
      '${connection.remoteDescription.host}:${connection.remoteDescription.port} '
      'transport=${connection.remoteDescription.transport}',
    );
    _messageSub = connection.receiveMessages().listen(
      (message) {
        _log(
          'Received control message ${message.type.name} '
          'connId=${_state.connectionId ?? 'unknown'}',
        );
        _messages.add(message);
      },
      onError: (error, stack) {
        final failure = _classifyFailure(message: '$error');
        _log(
          'Control message stream error '
          'connId=${_state.connectionId ?? 'unknown'} '
          'failure=${failure?.type.name ?? 'unknown'} '
          'detail=$error',
        );
        _fail(
          failure ?? ControlFailure(ControlFailureType.transport, '$error'),
        );
      },
      onDone: () => _shutdown(),
    );
    _eventSub = connection.connectionEvents().listen(_handleConnectionEvent);
  }

  final ControlConnection _connection;
  final _messages = StreamController<ControlMessage>.broadcast();
  final _stateController = StreamController<ControlChannelState>.broadcast();
  final Queue<_OutboundRequest> _outbound = Queue();
  StreamSubscription<ControlMessage>? _messageSub;
  StreamSubscription<ControlConnectionEvent>? _eventSub;
  _OutboundRequest? _inFlight;
  bool _sending = false;
  bool _closed = false;
  late ControlChannelState _state;

  Stream<ControlMessage> get incomingMessages => _messages.stream;
  Stream<ControlChannelState> get states => _stateController.stream;
  ControlChannelState get state => _state;

  Future<void> send(ControlMessage message, {String? connectionId}) {
    if (_closed) {
      return Future.error(ControlChannelClosedException(_state.failure));
    }
    final request = _OutboundRequest(message, connectionId);
    _outbound.add(request);
    _pumpQueue();
    return request.completer.future;
  }

  Future<void> dispose() => _shutdown();

  void _pumpQueue() {
    if (_sending || _closed || _outbound.isEmpty) return;
    _sending = true;
    final request = _outbound.removeFirst();
    _inFlight = request;
    _log(
      'Sending control message ${request.message.type.name} '
      'connId=${request.connectionId ?? _state.connectionId ?? 'unknown'}',
    );
    _connection
        .sendMessage(request.message, connectionId: request.connectionId)
        .then((_) {
          if (!request.completer.isCompleted) {
            request.completer.complete();
          }
        })
        .catchError((error, stack) {
          final failure =
              _classifyFailure(message: '$error') ??
              ControlFailure(ControlFailureType.transport, '$error');
          if (!request.completer.isCompleted) {
            request.completer.completeError(error, stack);
          }
          _fail(failure);
        })
        .whenComplete(() {
          _inFlight = null;
          _sending = false;
          _pumpQueue();
        });
  }

  void _handleConnectionEvent(ControlConnectionEvent event) {
    if (_closed) return;
    if (event is ControlConnected) {
      _log(
        'Control connection established '
        'connId=${event.connectionId} '
        'peerFp=${_shortFingerprint(event.peerFingerprint)}',
      );
      _emitState(
        ControlChannelState.connected(
          connectionId: event.connectionId!,
          peerFingerprint: event.peerFingerprint,
        ),
      );
    } else if (event is ControlConnectionClosed) {
      final failure = _classifyFailure(reason: event.reason);
      _log(
        'Control connection closed connId=${event.connectionId ?? _state.connectionId} '
        'reason=${event.reason ?? 'none'}',
      );
      if (failure != null) {
        _fail(failure, connectionId: event.connectionId ?? _state.connectionId);
      } else {
        _emitState(
          ControlChannelState.closed(
            connectionId: event.connectionId ?? _state.connectionId,
            peerFingerprint: _state.peerFingerprint,
          ),
        );
        _shutdown();
      }
    } else if (event is ControlConnectionError) {
      final failure =
          _classifyFailure(message: event.message) ??
          ControlFailure(ControlFailureType.transport, event.message);
      _log(
        'Control connection error connId=${event.connectionId ?? _state.connectionId} '
        'error=${failure.type.name}: ${failure.message}',
      );
      _fail(failure, connectionId: event.connectionId ?? _state.connectionId);
    }
  }

  void _emitState(ControlChannelState next) {
    _state = next;
    _stateController.add(next);
  }

  ControlFailure? _classifyFailure({String? reason, String? message}) {
    final combined = '${reason ?? ''} ${message ?? ''}'.trim();
    if (combined.isEmpty) return null;
    final lower = combined.toLowerCase();
    if (lower.contains('fingerprint mismatch')) {
      return ControlFailure(
        ControlFailureType.fingerprintMismatch,
        'Server fingerprint mismatch',
      );
    }
    if (lower.contains('untrusted client')) {
      return ControlFailure(
        ControlFailureType.untrustedClient,
        'Client is not paired or pinned on the monitor',
      );
    }
    if (lower.contains('protocol')) {
      return ControlFailure(
        ControlFailureType.protocolViolation,
        'Protocol violation on control stream',
      );
    }
    if (lower.contains('timeout') || lower.contains('idle')) {
      return ControlFailure(
        ControlFailureType.timeout,
        'Control channel timed out',
      );
    }
    if (lower.contains('closed')) {
      return ControlFailure(
        ControlFailureType.closed,
        reason ?? message ?? 'Connection closed',
      );
    }
    if (lower.contains('error')) {
      return ControlFailure(
        ControlFailureType.transport,
        reason ?? message ?? 'Transport error',
      );
    }
    return ControlFailure(
      ControlFailureType.unknown,
      reason ?? message ?? 'Unknown control failure',
    );
  }

  Future<void> _fail(ControlFailure failure, {String? connectionId}) async {
    if (_closed) return;
    _log(
      'Failing control channel connId=${connectionId ?? _state.connectionId} '
      'reason=${failure.type.name}: ${failure.message}',
    );
    _emitState(
      ControlChannelState.error(
        connectionId: connectionId ?? _state.connectionId,
        peerFingerprint: _state.peerFingerprint,
        failure: failure,
      ),
    );
    await _shutdown(failure: failure);
  }

  Future<void> _shutdown({ControlFailure? failure}) async {
    if (_closed) return;
    _closed = true;
    _log(
      'Shutting down control channel connId=${_state.connectionId ?? 'unknown'} '
      'failure=${failure?.type.name ?? 'none'}',
    );
    final closedFailure = ControlChannelClosedException(failure);
    final inFlight = _inFlight;
    _inFlight = null;
    if (inFlight != null && !inFlight.completer.isCompleted) {
      inFlight.completer.completeError(closedFailure);
    }
    while (_outbound.isNotEmpty) {
      final pending = _outbound.removeFirst();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(closedFailure);
      }
    }
    _sending = false;
    if (!_stateController.isClosed &&
        _state.status == ControlChannelStatus.connecting &&
        failure == null) {
      _emitState(
        ControlChannelState.closed(
          connectionId: _state.connectionId,
          peerFingerprint: _state.peerFingerprint,
        ),
      );
    }
    await _eventSub?.cancel();
    await _messageSub?.cancel();
    await _connection.close();
    await _messages.close();
    await _stateController.close();
  }
}

class _OutboundRequest {
  _OutboundRequest(this.message, this.connectionId);

  final ControlMessage message;
  final String? connectionId;
  final Completer<void> completer = Completer<void>();
}

const _log = Logger('control_channel');

String _shortFingerprint(String fingerprint) {
  if (fingerprint.length <= 12) return fingerprint;
  return fingerprint.substring(0, 12);
}
