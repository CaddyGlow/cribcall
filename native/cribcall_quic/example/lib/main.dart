import 'package:flutter/material.dart';
import 'package:cribcall_quic/cribcall_quic.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String version = '';
  String status = 'Loading...';

  @override
  void initState() {
    super.initState();
    _init();
  }

  void _init() {
    try {
      final quic = CribcallQuic();
      quic.initLogging();
      final cfg = quic.createConfig();
      cfg.dispose();
      setState(() {
        version = quic.version();
        status = 'Rust/quiche config ready';
      });
    } on Exception catch (error) {
      setState(() {
        status = 'Init failed: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(fontSize: 25);
    const spacerSmall = SizedBox(height: 10);
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Native Packages')),
        body: SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                const Text(
                  'CribCall QUIC (Rust via Cargokit)',
                  style: textStyle,
                ),
                spacerSmall,
                Text(
                  'Version: $version',
                  style: textStyle,
                  textAlign: TextAlign.center,
                ),
                spacerSmall,
                Text(status, style: textStyle, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
