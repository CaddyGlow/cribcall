import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Services are now managed by ServiceCoordinator via serviceLifecycleProvider.
  // The coordinator starts/stops services based on the app's role and state.

  runApp(const ProviderScope(child: CribCallApp()));
}
