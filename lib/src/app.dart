import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/listener/noise_event_handler.dart';
import 'notifications/notification_action_handler.dart';
import 'routing/app_router.dart';
import 'theme.dart';

class CribCallApp extends ConsumerStatefulWidget {
  const CribCallApp({super.key});

  @override
  ConsumerState<CribCallApp> createState() => _CribCallAppState();
}

class _CribCallAppState extends ConsumerState<CribCallApp> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = ref.read(routerProvider);

    // Initialize notification action handler after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationActionHandler.instance.initialize(
        router: _router,
        ref: ref,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'CribCall',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      routerConfig: _router,
      builder: (context, child) {
        return NoiseEventHandler(
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
