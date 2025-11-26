import 'package:flutter/material.dart';

import 'features/landing/role_selection_page.dart';
import 'features/listener/noise_event_handler.dart';
import 'theme.dart';

class CribCallApp extends StatelessWidget {
  const CribCallApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CribCall',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const NoiseEventHandler(
        child: RoleSelectionPage(),
      ),
    );
  }
}
