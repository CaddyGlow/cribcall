import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app.dart';
import 'src/fcm/fcm_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize FCM for push notifications (Listener role)
  try {
    await FcmService.instance.initialize();
  } catch (e) {
    debugPrint('FCM initialization failed: $e');
    // Continue without FCM - WebSocket will still work
  }

  runApp(const ProviderScope(child: CribCallApp()));
}
