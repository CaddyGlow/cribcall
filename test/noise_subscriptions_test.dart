import 'dart:io';

import 'package:cribcall/src/domain/noise_subscription.dart';
import 'package:cribcall/src/domain/models.dart';
import 'package:cribcall/src/state/app_state.dart';
import 'package:cribcall/src/storage/noise_subscriptions_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NoiseSubscriptionsController', () {
    late Directory tempDir;
    late ProviderContainer container;
    const peer = TrustedPeer(
      remoteDeviceId: 'listener-1',
      name: 'Listener One',
      certFingerprint: 'abc123fingerprint',
      addedAtEpochSec: 0,
    );

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('noise_subs');
      container = ProviderContainer(
        overrides: [
          noiseSubscriptionsRepoProvider.overrideWithValue(
            NoiseSubscriptionsRepository(overrideDirectoryPath: tempDir.path),
          ),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await tempDir.delete(recursive: true);
    });

    test('upsert stores single active token per device', () async {
      final controller = container.read(noiseSubscriptionsProvider.notifier);

      final first = await controller.upsert(
        peer: peer,
        fcmToken: 'token-1',
        platform: 'android',
        leaseSeconds: 3600,
      );
      expect(first.acceptedLeaseSeconds, 3600);

      final second = await controller.upsert(
        peer: peer,
        fcmToken: 'token-2',
        platform: 'android',
        leaseSeconds: kNoiseSubscriptionDefaultLease.inSeconds,
      );

      final subs = container.read(noiseSubscriptionsProvider).value!;
      expect(subs.length, 1);
      expect(subs.single.fcmToken, 'token-2');
      expect(
        subs.single.subscriptionId,
        noiseSubscriptionId(peer.remoteDeviceId, 'token-2'),
      );
      expect(second.subscription.subscriptionId, subs.single.subscriptionId);
    });

    test('unsubscribe removes matching token', () async {
      final controller = container.read(noiseSubscriptionsProvider.notifier);
      await controller.upsert(
        peer: peer,
        fcmToken: 'token-1',
        platform: 'android',
        leaseSeconds: null,
      );

      final removed = await controller.unsubscribe(
        peer: peer,
        fcmToken: 'token-1',
      );
      expect(removed, isNotNull);
      expect(container.read(noiseSubscriptionsProvider).value, isEmpty);
    });

    test('websocket-only helpers flag ws-only tokens', () {
      final token = websocketOnlyNoiseToken(peer.remoteDeviceId);
      final now = DateTime.now();
      final sub = NoiseSubscription(
        deviceId: peer.remoteDeviceId,
        certFingerprint: peer.certFingerprint,
        fcmToken: token,
        platform: 'linux',
        expiresAtEpochSec:
            now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
        createdAtEpochSec: now.millisecondsSinceEpoch ~/ 1000,
        subscriptionId: noiseSubscriptionId(peer.remoteDeviceId, token),
      );

      expect(isWebsocketOnlyNoiseToken(token), isTrue);
      expect(sub.isWebsocketOnly, isTrue);
    });
  });
}
