import 'dart:convert';

/// WebSocket control message types (post-pairing).
/// These are exchanged over the mTLS WebSocket connection.
enum ControlMessageType {
  noiseEvent('NOISE_EVENT'),
  startStreamRequest('START_STREAM_REQUEST'),
  startStreamResponse('START_STREAM_RESPONSE'),
  endStream('END_STREAM'),
  pinStream('PIN_STREAM'),
  webrtcOffer('WEBRTC_OFFER'),
  webrtcAnswer('WEBRTC_ANSWER'),
  webrtcIce('WEBRTC_ICE'),
  ping('PING'),
  pong('PONG'),
  fcmTokenUpdate('FCM_TOKEN_UPDATE');

  const ControlMessageType(this.wireValue);

  final String wireValue;

  static ControlMessageType fromWire(String raw) {
    return ControlMessageType.values.firstWhere(
      (t) => t.wireValue == raw,
      orElse: () => throw FormatException('Unsupported message type: $raw'),
    );
  }
}

/// Base class for all WebSocket control messages
abstract class ControlMessage {
  ControlMessageType get type;

  Map<String, dynamic> toJson();

  Map<String, dynamic> toWireJson() => {'type': type.wireValue, ...toJson()};

  String toJsonString() => jsonEncode(toWireJson());
}

class NoiseEventMessage extends ControlMessage {
  NoiseEventMessage({
    required this.deviceId,
    required this.timestamp,
    required this.peakLevel,
  });

  final String deviceId;
  final int timestamp;
  final int peakLevel;

  @override
  ControlMessageType get type => ControlMessageType.noiseEvent;

  factory NoiseEventMessage.fromJson(Map<String, dynamic> json) {
    return NoiseEventMessage(
      deviceId: json['deviceId'] as String,
      timestamp: json['timestamp'] as int,
      peakLevel: json['peakLevel'] as int,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'timestamp': timestamp,
        'peakLevel': peakLevel,
      };
}

class StartStreamRequestMessage extends ControlMessage {
  StartStreamRequestMessage({required this.sessionId, required this.mediaType});

  final String sessionId;
  final String mediaType; // "audio" | "audio_video"

  @override
  ControlMessageType get type => ControlMessageType.startStreamRequest;

  factory StartStreamRequestMessage.fromJson(Map<String, dynamic> json) {
    return StartStreamRequestMessage(
      sessionId: json['sessionId'] as String,
      mediaType: json['mediaType'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'mediaType': mediaType,
      };
}

class StartStreamResponseMessage extends ControlMessage {
  StartStreamResponseMessage({
    required this.sessionId,
    required this.accepted,
    this.reason,
  });

  final String sessionId;
  final bool accepted;
  final String? reason;

  @override
  ControlMessageType get type => ControlMessageType.startStreamResponse;

  factory StartStreamResponseMessage.fromJson(Map<String, dynamic> json) {
    return StartStreamResponseMessage(
      sessionId: json['sessionId'] as String,
      accepted: json['accepted'] as bool,
      reason: json['reason'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'accepted': accepted,
        if (reason != null) 'reason': reason,
      };
}

class EndStreamMessage extends ControlMessage {
  EndStreamMessage({required this.sessionId});

  final String sessionId;

  @override
  ControlMessageType get type => ControlMessageType.endStream;

  factory EndStreamMessage.fromJson(Map<String, dynamic> json) {
    return EndStreamMessage(sessionId: json['sessionId'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {'sessionId': sessionId};
}

class PinStreamMessage extends ControlMessage {
  PinStreamMessage({required this.sessionId});

  final String sessionId;

  @override
  ControlMessageType get type => ControlMessageType.pinStream;

  factory PinStreamMessage.fromJson(Map<String, dynamic> json) {
    return PinStreamMessage(sessionId: json['sessionId'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {'sessionId': sessionId};
}

class WebRtcOfferMessage extends ControlMessage {
  WebRtcOfferMessage({required this.sessionId, required this.sdp});

  final String sessionId;
  final String sdp;

  @override
  ControlMessageType get type => ControlMessageType.webrtcOffer;

  factory WebRtcOfferMessage.fromJson(Map<String, dynamic> json) {
    return WebRtcOfferMessage(
      sessionId: json['sessionId'] as String,
      sdp: json['sdp'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() => {'sessionId': sessionId, 'sdp': sdp};
}

class WebRtcAnswerMessage extends ControlMessage {
  WebRtcAnswerMessage({required this.sessionId, required this.sdp});

  final String sessionId;
  final String sdp;

  @override
  ControlMessageType get type => ControlMessageType.webrtcAnswer;

  factory WebRtcAnswerMessage.fromJson(Map<String, dynamic> json) {
    return WebRtcAnswerMessage(
      sessionId: json['sessionId'] as String,
      sdp: json['sdp'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() => {'sessionId': sessionId, 'sdp': sdp};
}

class WebRtcIceMessage extends ControlMessage {
  WebRtcIceMessage({required this.sessionId, required this.candidate});

  final String sessionId;
  final Map<String, dynamic> candidate;

  @override
  ControlMessageType get type => ControlMessageType.webrtcIce;

  factory WebRtcIceMessage.fromJson(Map<String, dynamic> json) {
    return WebRtcIceMessage(
      sessionId: json['sessionId'] as String,
      candidate: (json['candidate'] as Map).cast<String, dynamic>(),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'candidate': candidate,
      };
}

class PingMessage extends ControlMessage {
  PingMessage({required this.timestamp});

  final int timestamp;

  @override
  ControlMessageType get type => ControlMessageType.ping;

  factory PingMessage.fromJson(Map<String, dynamic> json) {
    return PingMessage(timestamp: json['timestamp'] as int);
  }

  @override
  Map<String, dynamic> toJson() => {'timestamp': timestamp};
}

class PongMessage extends ControlMessage {
  PongMessage({required this.timestamp});

  final int timestamp;

  @override
  ControlMessageType get type => ControlMessageType.pong;

  factory PongMessage.fromJson(Map<String, dynamic> json) {
    return PongMessage(timestamp: json['timestamp'] as int);
  }

  @override
  Map<String, dynamic> toJson() => {'timestamp': timestamp};
}

/// Message sent by Listener to Monitor to share/update FCM token.
/// This enables Monitor to send push notifications via FCM.
class FcmTokenUpdateMessage extends ControlMessage {
  FcmTokenUpdateMessage({
    required this.fcmToken,
    required this.deviceId,
  });

  final String fcmToken;
  final String deviceId;

  @override
  ControlMessageType get type => ControlMessageType.fcmTokenUpdate;

  factory FcmTokenUpdateMessage.fromJson(Map<String, dynamic> json) {
    return FcmTokenUpdateMessage(
      fcmToken: json['fcmToken'] as String,
      deviceId: json['deviceId'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'fcmToken': fcmToken,
        'deviceId': deviceId,
      };
}

/// Factory to deserialize control messages from wire format
class ControlMessageFactory {
  static ControlMessage fromWireJson(Map<String, dynamic> json) {
    final typeValue = json['type'];
    if (typeValue is! String) {
      throw const FormatException('Control message missing type');
    }
    final type = ControlMessageType.fromWire(typeValue);
    final body = Map<String, dynamic>.of(json)..remove('type');

    switch (type) {
      case ControlMessageType.noiseEvent:
        return NoiseEventMessage.fromJson(body);
      case ControlMessageType.startStreamRequest:
        return StartStreamRequestMessage.fromJson(body);
      case ControlMessageType.startStreamResponse:
        return StartStreamResponseMessage.fromJson(body);
      case ControlMessageType.endStream:
        return EndStreamMessage.fromJson(body);
      case ControlMessageType.pinStream:
        return PinStreamMessage.fromJson(body);
      case ControlMessageType.webrtcOffer:
        return WebRtcOfferMessage.fromJson(body);
      case ControlMessageType.webrtcAnswer:
        return WebRtcAnswerMessage.fromJson(body);
      case ControlMessageType.webrtcIce:
        return WebRtcIceMessage.fromJson(body);
      case ControlMessageType.ping:
        return PingMessage.fromJson(body);
      case ControlMessageType.pong:
        return PongMessage.fromJson(body);
      case ControlMessageType.fcmTokenUpdate:
        return FcmTokenUpdateMessage.fromJson(body);
    }
  }

  static ControlMessage? tryFromWireJson(Map<String, dynamic> json) {
    try {
      return fromWireJson(json);
    } catch (_) {
      return null;
    }
  }
}
