class WebRtcConfig {
  const WebRtcConfig({
    this.iceServers = const [],
    this.hostOnly = true,
    this.preferH264 = true,
    this.maxBitrateBps = 1500000,
    this.audioDtx = true,
    this.audioFec = true,
  });

  final List<Map<String, String>> iceServers;
  final bool hostOnly;
  final bool preferH264;
  final int maxBitrateBps;
  final bool audioDtx;
  final bool audioFec;

  Map<String, dynamic> toMap() => {
        'iceServers': iceServers,
        'iceTransportPolicy': hostOnly ? 'all' : 'all',
        'sdpSemantics': 'unified-plan',
        'codecPreferences': {
          'audio': ['opus'],
          'video': preferH264 ? ['H264', 'VP8'] : ['VP8', 'H264'],
        },
        'audio': {
          'dtx': audioDtx,
          'fec': audioFec,
        },
        'bitrate': maxBitrateBps,
      };
}
