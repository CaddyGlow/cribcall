/// Stub implementations for platforms without WebRTC support.

class RTCVideoRenderer {
  Future<void> initialize() async {}
  void dispose() {}
  set srcObject(dynamic stream) {}
  dynamic get srcObject => null;
}

class MediaStream {
  List<dynamic> getVideoTracks() => [];
  Future<void> dispose() async {}
}
