import 'dart:async';
import 'dart:convert';

import '../config/build_flags.dart';
import '../control/control_channel.dart';
import '../control/control_message.dart';
import '../control/control_transport.dart';
import '../control/http_transport.dart';
import '../domain/models.dart';
import '../identity/device_identity.dart';

class MonitorCliHarness {
  MonitorCliHarness({
    required this.identity,
    this.port = kControlDefaultPort,
    Iterable<String> trustedFingerprints = const [],
    bool allowUntrustedClients = false,
    bool useTls = true,
    this.trustedClientCertificates = const [],
    this.logger,
    this.onTrustedListener,
    this.onMessage,
    HttpControlServer? server,
  })  : _trustedFingerprints = {...trustedFingerprints},
        _server = server ??
            HttpControlServer(
              useTls: useTls,
              allowUntrustedClients: allowUntrustedClients,
            );

  final DeviceIdentity identity;
  final int port;
  final HttpControlServer _server;
  final Set<String> _trustedFingerprints;
  final List<List<int>> trustedClientCertificates;
  final void Function(String message)? logger;
  final void Function(TrustedPeer peer)? onTrustedListener;
  final void Function(ControlMessage message)? onMessage;
  final List<StreamSubscription> _subscriptions = [];
  bool _started = false;

  int? get boundPort => _server.boundPort;

  Set<String> get trustedFingerprints => Set.unmodifiable(_trustedFingerprints);

  Future<void> start() async {
    if (_started) return;
    _server.setPairingMessageHandler(_handlePairingMessage);
    await _server.start(
      port: port,
      serverIdentity: identity,
      trustedListenerFingerprints: _trustedFingerprints.toList(),
      trustedClientCertificates: trustedClientCertificates,
    );
    _started = true;
    _log(
      'Monitor control server listening on ${_server.boundPort ?? port} '
      'fingerprint=${_shortFp(identity.certFingerprint)} '
      'trusted=${_trustedFingerprints.length}',
    );
  }

  Future<void> stop() async {
    if (!_started) return;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    await _server.stop();
    _started = false;
  }

  Future<void> _handlePairingMessage(
    ControlMessage message,
    HttpControlConnection connection,
  ) async {
    if (message is PairRequestMessage) {
      await _handlePairRequest(message, connection);
      return;
    }
    if (message is PinPairingInitMessage) {
      _log(
        'PIN_PAIRING_INIT received (not validated in CLI harness) '
        'listener=${message.listenerId} '
        'fingerprint=${_shortFp(message.listenerCertFingerprint)}',
      );
      return;
    }
    if (message is PinSubmitMessage) {
      _log(
        'PIN_SUBMIT received (not validated in CLI harness) '
        'pairingSessionId=${message.pairingSessionId}',
      );
    }
  }

  Future<void> _handlePairRequest(
    PairRequestMessage message,
    HttpControlConnection connection,
  ) async {
    final peerFp = message.listenerCertFingerprint;
    if (peerFp != connection.peerFingerprint &&
        connection.peerFingerprint.isNotEmpty) {
      _log(
        'Rejecting PAIR_REQUEST due to fingerprint mismatch '
        'msg=${_shortFp(peerFp)} peer=${_shortFp(connection.peerFingerprint)}',
      );
      await connection.sendMessage(
        PairRejectedMessage(reason: 'fingerprint mismatch'),
      );
      return;
    }

    final newlyTrusted = _trustedFingerprints.add(peerFp);
    if (newlyTrusted) {
      _server.addTrustedFingerprint(peerFp);
      _log(
        'Trusted listener added id=${message.listenerId} '
        'name=${message.listenerName} '
        'fingerprint=${_shortFp(peerFp)} '
        'trustedCount=${_trustedFingerprints.length}',
      );
    } else {
      _log(
        'Listener already trusted id=${message.listenerId} '
        'fingerprint=${_shortFp(peerFp)}',
      );
    }

    connection.elevateToTrusted();
    final peer = TrustedPeer(
      deviceId: message.listenerId,
      name: message.listenerName,
      certFingerprint: peerFp,
      addedAtEpochSec: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    onTrustedListener?.call(peer);

    await connection.sendMessage(
      PairAcceptedMessage(monitorId: identity.deviceId),
    );
    _attachConnectionListeners(connection);
  }

  void _attachConnectionListeners(HttpControlConnection connection) {
    final messageSub = connection.receiveMessages().listen((message) async {
      onMessage?.call(message);
      if (message is PingMessage) {
        await connection.sendMessage(PongMessage(timestamp: message.timestamp));
        _log(
          'Ping received on connId=${connection.connectionId}; pong sent '
          'ts=${message.timestamp}',
        );
      } else if (message is NoiseEventMessage) {
        _log(
          'NOISE_EVENT monitorId=${message.monitorId} '
          'peak=${message.peakLevel} '
          'ts=${message.timestamp}',
        );
      }
    });

    final eventSub = connection.connectionEvents().listen((event) {
      if (event is ControlConnectionClosed) {
        _log(
          'Control connection ${event.connectionId ?? connection.connectionId} '
          'closed reason=${event.reason ?? 'closed'}',
        );
      } else if (event is ControlConnectionError) {
        _log(
          'Control connection error ${event.connectionId ?? connection.connectionId} '
          'message=${event.message}',
        );
      }
    });

    _subscriptions
      ..add(messageSub)
      ..add(eventSub);
  }

  void _log(String message) {
    logger?.call(message);
  }
}

class ListenerCliHarness {
  ListenerCliHarness({
    required this.identity,
    required this.endpoint,
    this.listenerName = 'CLI Listener',
    this.allowUnpinned = false,
    bool useTls = true,
    this.logger,
    this.onMessage,
  }) : _client = HttpControlClient(useTls: useTls);

  final DeviceIdentity identity;
  final ControlEndpoint endpoint;
  final String listenerName;
  final bool allowUnpinned;
  final void Function(String message)? logger;
  final void Function(ControlMessage message)? onMessage;

  final HttpControlClient _client;
  ControlChannel? _channel;
  StreamSubscription<ControlMessage>? _messageSub;
  StreamSubscription<ControlChannelState>? _stateSub;
  bool _pairRequestSent = false;
  bool _stopped = false;

  Future<ListenerRunResult> start({bool sendPingAfterPair = false}) async {
    _stopped = false;
    _pairRequestSent = false;
    try {
      final connection = await _client.connect(
        endpoint: endpoint,
        clientIdentity: identity,
        allowUnpinned: allowUnpinned,
      );
      _channel = ControlChannel(connection: connection);
      final result = Completer<ListenerRunResult>();

      _messageSub = _channel!.incomingMessages.listen((message) async {
        onMessage?.call(message);
        if (message is PairAcceptedMessage && !result.isCompleted) {
          _log(
            'PAIR_ACCEPTED from monitor=${message.monitorId} '
            'connId=${_channel?.state.connectionId ?? 'unknown'}',
          );
          if (sendPingAfterPair) {
            await _channel?.send(
              PingMessage(timestamp: DateTime.now().millisecondsSinceEpoch),
            );
          }
          result.complete(
            ListenerRunResult.paired(
              connectionId: _channel?.state.connectionId,
              peerFingerprint:
                  _client.lastSeenFingerprint ??
                  endpoint.expectedServerFingerprint,
            ),
          );
        } else if (message is PairRejectedMessage && !result.isCompleted) {
          final failure = ControlFailure(
            ControlFailureType.untrustedClient,
            message.reason,
          );
          _log('PAIR_REJECTED: ${message.reason}');
          result.complete(ListenerRunResult.failed(failure));
        } else if (message is PongMessage) {
          _log('PONG ts=${message.timestamp}');
        } else if (message is PingMessage) {
          await _channel?.send(PongMessage(timestamp: message.timestamp));
        } else if (message is NoiseEventMessage) {
          _log(
            'NOISE_EVENT monitorId=${message.monitorId} '
            'peak=${message.peakLevel} '
            'ts=${message.timestamp}',
          );
        }
      });

      _stateSub = _channel!.states.listen((state) {
        switch (state.status) {
          case ControlChannelStatus.connected:
            if (_pairRequestSent) return;
            _pairRequestSent = true;
            final pairRequest = PairRequestMessage(
              listenerId: identity.deviceId,
              listenerName: listenerName,
              listenerPublicKey: base64.encode(identity.publicKey.bytes),
              listenerCertFingerprint: identity.certFingerprint,
            );
            _log(
              'Control channel connected; sending PAIR_REQUEST '
              'listenerId=${pairRequest.listenerId} '
              'fingerprint=${_shortFp(pairRequest.listenerCertFingerprint)}',
            );
            _channel?.send(pairRequest, connectionId: state.connectionId);
            break;
          case ControlChannelStatus.error:
            final failure =
                state.failure ??
                ControlFailure(
                  ControlFailureType.transport,
                  'Control channel error',
                );
            if (!result.isCompleted) {
              result.complete(ListenerRunResult.failed(failure));
            }
            break;
          case ControlChannelStatus.closed:
            if (!result.isCompleted) {
              result.complete(
                ListenerRunResult.failed(
                  ControlFailure(
                    ControlFailureType.closed,
                    'Control channel closed',
                  ),
                ),
              );
            }
            break;
          case ControlChannelStatus.connecting:
            break;
        }
      });

      return result.future;
    } catch (e) {
      final failure = ControlFailure(ControlFailureType.transport, '$e');
      if ('$e'.contains('NO_COMMON_SIGNATURE_ALGORITHMS')) {
        _log(
          'TLS handshake failed (certificate signature not supported by this '
          'runtime): $e',
        );
      } else {
        _log('Control client failed: $e');
      }
      return ListenerRunResult.failed(failure);
    }
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _messageSub?.cancel();
    await _stateSub?.cancel();
    await _channel?.dispose();
    _pairRequestSent = false;
    _messageSub = null;
    _stateSub = null;
    _channel = null;
  }

  void _log(String message) {
    logger?.call(message);
  }
}

class ListenerRunResult {
  const ListenerRunResult._({
    required this.paired,
    this.failure,
    this.connectionId,
    this.peerFingerprint,
  });

  final bool paired;
  final ControlFailure? failure;
  final String? connectionId;
  final String? peerFingerprint;

  bool get ok => paired && failure == null;

  factory ListenerRunResult.paired({
    String? connectionId,
    String? peerFingerprint,
  }) {
    return ListenerRunResult._(
      paired: true,
      connectionId: connectionId,
      peerFingerprint: peerFingerprint,
    );
  }

  factory ListenerRunResult.failed(ControlFailure failure) {
    return ListenerRunResult._(paired: false, failure: failure);
  }
}

String _shortFp(String fingerprint) {
  if (fingerprint.length <= 12) return fingerprint;
  final prefix = fingerprint.substring(0, 6);
  final suffix = fingerprint.substring(fingerprint.length - 4);
  return '$prefix...$suffix';
}
