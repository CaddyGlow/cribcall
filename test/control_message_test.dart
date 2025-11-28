import 'package:flutter_test/flutter_test.dart';

import 'package:cribcall/src/control/control_message.dart';

void main() {
  test('control message factory parses known types', () {
    final raw = {
      'type': 'PAIR_REQUEST',
      'deviceId': 'L1',
      'deviceName': 'Parent',
      'publicKey': 'pub',
      'certFingerprint': 'ff',
    };

    final message = ControlMessageFactory.fromWireJson(raw);
    expect(message, isA<PairRequestMessage>());
    expect(message.toWireJson()['type'], 'PAIR_REQUEST');
  });

  test('throws on unsupported type', () {
    final raw = {'type': 'UNKNOWN'};
    expect(
      () => ControlMessageFactory.fromWireJson(raw),
      throwsFormatException,
    );
  });
}
