import 'dart:async';
import 'dart:collection';

import 'package:cribcall/src/control/control_channel.dart';
import 'package:cribcall/src/control/control_message.dart';
import 'package:cribcall/src/control/quic_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'ControlChannel transitions to connected and forwards messages',
    () async {
      final connection = FakeQuicControlConnection();
      final channel = ControlChannel(connection: connection);

      final states = <ControlChannelState>[];
      final stateSub = channel.states.listen(states.add);

      connection.pushEvent(
        const ControlConnected(connectionId: 'abc', peerFingerprint: 'fp'),
      );
      connection.pushMessage(PingMessage(timestamp: 1));

      final message = await channel.incomingMessages.first;
      expect(message, isA<PingMessage>());
      expect(
        states.any((s) => s.status == ControlChannelStatus.connected),
        isTrue,
      );

      await channel.dispose();
      await stateSub.cancel();
    },
  );

  test('ControlChannel queues outbound sends', () async {
    final connection = FakeQuicControlConnection();
    final channel = ControlChannel(connection: connection);

    final first = channel.send(PingMessage(timestamp: 1));
    final second = channel.send(PingMessage(timestamp: 2));

    expect(connection.sentMessages.length, 1);
    connection.completeNextSend();
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(connection.sentMessages.length, 2);
    connection.completeNextSend();
    await second;

    await channel.dispose();
  });

  test('ControlChannel maps failures from connection events', () async {
    final connection = FakeQuicControlConnection();
    final channel = ControlChannel(connection: connection);

    final states = <ControlChannelState>[];
    final sub = channel.states.listen(states.add);

    connection.pushEvent(
      const ControlConnectionError(
        connectionId: 'def',
        message: 'server fingerprint mismatch',
      ),
    );

    await Future<void>.delayed(Duration.zero);

    final errorState = states.lastWhere(
      (s) => s.status == ControlChannelStatus.error,
    );
    expect(errorState.failure?.type, ControlFailureType.fingerprintMismatch);

    await channel.dispose();
    await sub.cancel();
  });
}

class FakeQuicControlConnection extends QuicControlConnection {
  FakeQuicControlConnection()
    : super(
        remoteDescription: QuicEndpoint(
          host: 'localhost',
          port: 1234,
          expectedServerFingerprint: 'abc',
        ),
      );

  final _incoming = StreamController<ControlMessage>.broadcast();
  final _events = StreamController<ControlConnectionEvent>.broadcast();
  final Queue<Completer<void>> _pendingSends = Queue();
  final List<_SentMessage> sentMessages = [];

  @override
  Stream<ControlMessage> receiveMessages() => _incoming.stream;

  @override
  Stream<ControlConnectionEvent> connectionEvents() => _events.stream;

  @override
  Future<void> sendMessage(ControlMessage message, {String? connectionId}) {
    final completer = Completer<void>();
    _pendingSends.add(completer);
    sentMessages.add(_SentMessage(message, connectionId));
    return completer.future;
  }

  void pushEvent(ControlConnectionEvent event) => _events.add(event);

  void pushMessage(ControlMessage message) => _incoming.add(message);

  void completeNextSend() {
    if (_pendingSends.isEmpty) return;
    _pendingSends.removeFirst().complete();
  }

  @override
  Future<void> close() async {
    await _incoming.close();
    await _events.close();
    while (_pendingSends.isNotEmpty) {
      _pendingSends.removeFirst().complete();
    }
  }
}

class _SentMessage {
  _SentMessage(this.message, this.connectionId);

  final ControlMessage message;
  final String? connectionId;
}
