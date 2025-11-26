// Stub implementation for platforms without WebRTC support (Linux desktop)

import 'package:flutter/widgets.dart';

class RTCVideoRenderer {
  Future<void> initialize() async {}
  void dispose() {}
  set srcObject(dynamic stream) {}
  dynamic get srcObject => null;
}

class RTCVideoView extends StatelessWidget {
  const RTCVideoView(this.renderer, {super.key, this.objectFit});

  final RTCVideoRenderer renderer;
  final dynamic objectFit;

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

class RTCVideoViewObjectFit {
  static const RTCVideoViewObjectFitContain = null;
}
