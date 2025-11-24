import 'package:flutter_test/flutter_test.dart';

import 'package:cribcall/src/pairing/pairing_transcript.dart';

void main() {
  const transcript = PairingTranscript(
    monitorId: 'M1-UUID',
    listenerId: 'L1-UUID',
    listenerPublicKey: 'base64-key',
    listenerCertFingerprint: 'abc123',
    monitorCertFingerprint: 'def456',
    pairingSessionId: 'PS1-UUID',
  );

  test('canonical form follows RFC 8785 ordering', () {
    expect(
      transcript.canonicalForm(),
      '{"listenerCertFingerprint":"abc123","listenerId":"L1-UUID","listenerPublicKey":"base64-key","monitorCertFingerprint":"def456","monitorId":"M1-UUID","pairingSessionId":"PS1-UUID"}',
    );
  });

  test('auth tag uses HMAC-SHA256 over canonical JSON', () {
    final pairingKey = List<int>.filled(32, 1);
    expect(
      transcript.authTagBase64(pairingKey),
      'e+XpGu9GiQ9K9XhHhITFzpgDxLcsD1THNNjzlKg7KM0=',
    );
  });
}
