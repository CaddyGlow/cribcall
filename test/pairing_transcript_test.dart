import 'package:flutter_test/flutter_test.dart';

import 'package:cribcall/src/pairing/pairing_transcript.dart';

void main() {
  const transcript = PairingTranscript(
    remoteDeviceId: 'M1-UUID',
    deviceId: 'L1-UUID',
    publicKey: 'base64-key',
    certFingerprint: 'abc123',
    remoteCertFingerprint: 'def456',
    pairingSessionId: 'PS1-UUID',
  );

  test('canonical form follows RFC 8785 ordering', () {
    expect(
      transcript.canonicalForm(),
      '{"certFingerprint":"abc123","deviceId":"L1-UUID","pairingSessionId":"PS1-UUID","publicKey":"base64-key","remoteCertFingerprint":"def456","remoteDeviceId":"M1-UUID"}',
    );
  });

  test('auth tag uses HMAC-SHA256 over canonical JSON', () {
    final pairingKey = List<int>.filled(32, 1);
    expect(
      transcript.authTagBase64(pairingKey),
      '8UQxw0IqqZhHUUxynjSp+E11VMWD9yqpRjefXdtRy1M=',
    );
  });
}
