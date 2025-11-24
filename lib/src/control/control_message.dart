import 'dart:convert';

enum ControlMessageType {
  pairRequest('PAIR_REQUEST'),
  pairAccepted('PAIR_ACCEPTED'),
  pairRejected('PAIR_REJECTED'),
  pinPairingInit('PIN_PAIRING_INIT'),
  pinRequired('PIN_REQUIRED'),
  pinSubmit('PIN_SUBMIT'),
  noiseEvent('NOISE_EVENT'),
  startStreamRequest('START_STREAM_REQUEST'),
  startStreamResponse('START_STREAM_RESPONSE'),
  endStream('END_STREAM'),
  pinStream('PIN_STREAM'),
  webrtcOffer('WEBRTC_OFFER'),
  webrtcAnswer('WEBRTC_ANSWER'),
  webrtcIce('WEBRTC_ICE'),
  ping('PING'),
  pong('PONG');

  const ControlMessageType(this.wireValue);

  final String wireValue;

  static ControlMessageType fromWire(String raw) {
    return ControlMessageType.values.firstWhere(
      (t) => t.wireValue == raw,
      orElse: () => throw FormatException('Unsupported message type: $raw'),
    );
  }
}

abstract class ControlMessage {
  ControlMessageType get type;

  Map<String, dynamic> toJson();

  Map<String, dynamic> toWireJson() => {'type': type.wireValue, ...toJson()};

  String toJsonString() => jsonEncode(toWireJson());
}

class PairRequestMessage extends ControlMessage {
  PairRequestMessage({
    required this.listenerId,
    required this.listenerName,
    required this.listenerPublicKey,
    required this.listenerCertFingerprint,
  });

  final String listenerId;
  final String listenerName;
  final String listenerPublicKey;
  final String listenerCertFingerprint;

  @override
  ControlMessageType get type => ControlMessageType.pairRequest;

  factory PairRequestMessage.fromJson(Map<String, dynamic> json) {
    return PairRequestMessage(
      listenerId: json['listenerId'] as String,
      listenerName: json['listenerName'] as String,
      listenerPublicKey: json['listenerPublicKey'] as String,
      listenerCertFingerprint: json['listenerCertFingerprint'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'listenerId': listenerId,
    'listenerName': listenerName,
    'listenerPublicKey': listenerPublicKey,
    'listenerCertFingerprint': listenerCertFingerprint,
  };
}

class PairAcceptedMessage extends ControlMessage {
  PairAcceptedMessage({required this.monitorId});

  final String monitorId;

  @override
  ControlMessageType get type => ControlMessageType.pairAccepted;

  factory PairAcceptedMessage.fromJson(Map<String, dynamic> json) {
    return PairAcceptedMessage(monitorId: json['monitorId'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {'monitorId': monitorId};
}

class PairRejectedMessage extends ControlMessage {
  PairRejectedMessage({required this.reason});

  final String reason;

  @override
  ControlMessageType get type => ControlMessageType.pairRejected;

  factory PairRejectedMessage.fromJson(Map<String, dynamic> json) {
    return PairRejectedMessage(reason: json['reason'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {'reason': reason};
}

class PinPairingInitMessage extends ControlMessage {
  PinPairingInitMessage({
    required this.listenerId,
    required this.listenerName,
    required this.protocolVersion,
    required this.listenerCertFingerprint,
  });

  final String listenerId;
  final String listenerName;
  final int protocolVersion;
  final String listenerCertFingerprint;

  @override
  ControlMessageType get type => ControlMessageType.pinPairingInit;

  factory PinPairingInitMessage.fromJson(Map<String, dynamic> json) {
    return PinPairingInitMessage(
      listenerId: json['listenerId'] as String,
      listenerName: json['listenerName'] as String,
      protocolVersion: json['protocolVersion'] as int,
      listenerCertFingerprint: json['listenerCertFingerprint'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'listenerId': listenerId,
    'listenerName': listenerName,
    'protocolVersion': protocolVersion,
    'listenerCertFingerprint': listenerCertFingerprint,
  };
}

class PinRequiredMessage extends ControlMessage {
  PinRequiredMessage({
    required this.pairingSessionId,
    required this.pakeMsgA,
    required this.expiresInSec,
    required this.maxAttempts,
  });

  final String pairingSessionId;
  final String pakeMsgA;
  final int expiresInSec;
  final int maxAttempts;

  @override
  ControlMessageType get type => ControlMessageType.pinRequired;

  factory PinRequiredMessage.fromJson(Map<String, dynamic> json) {
    return PinRequiredMessage(
      pairingSessionId: json['pairingSessionId'] as String,
      pakeMsgA: json['pakeMsgA'] as String,
      expiresInSec: json['expiresInSec'] as int,
      maxAttempts: json['maxAttempts'] as int,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'pairingSessionId': pairingSessionId,
    'pakeMsgA': pakeMsgA,
    'expiresInSec': expiresInSec,
    'maxAttempts': maxAttempts,
  };
}

class PinSubmitMessage extends ControlMessage {
  PinSubmitMessage({
    required this.pairingSessionId,
    required this.pakeMsgB,
    required this.transcript,
    required this.authTag,
  });

  final String pairingSessionId;
  final String pakeMsgB;
  final Map<String, dynamic> transcript;
  final String authTag;

  @override
  ControlMessageType get type => ControlMessageType.pinSubmit;

  factory PinSubmitMessage.fromJson(Map<String, dynamic> json) {
    return PinSubmitMessage(
      pairingSessionId: json['pairingSessionId'] as String,
      pakeMsgB: json['pakeMsgB'] as String,
      transcript: (json['transcript'] as Map).cast<String, dynamic>(),
      authTag: json['authTag'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'pairingSessionId': pairingSessionId,
    'pakeMsgB': pakeMsgB,
    'transcript': transcript,
    'authTag': authTag,
  };
}

class NoiseEventMessage extends ControlMessage {
  NoiseEventMessage({
    required this.monitorId,
    required this.timestamp,
    required this.peakLevel,
  });

  final String monitorId;
  final int timestamp;
  final int peakLevel;

  @override
  ControlMessageType get type => ControlMessageType.noiseEvent;

  factory NoiseEventMessage.fromJson(Map<String, dynamic> json) {
    return NoiseEventMessage(
      monitorId: json['monitorId'] as String,
      timestamp: json['timestamp'] as int,
      peakLevel: json['peakLevel'] as int,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
    'monitorId': monitorId,
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

class ControlMessageFactory {
  static ControlMessage fromWireJson(Map<String, dynamic> json) {
    final typeValue = json['type'];
    if (typeValue is! String) {
      throw const FormatException('Control message missing type');
    }
    final type = ControlMessageType.fromWire(typeValue);
    Map<String, dynamic> body = Map.of(json);
    body.remove('type');

    switch (type) {
      case ControlMessageType.pairRequest:
        return PairRequestMessage.fromJson(body);
      case ControlMessageType.pairAccepted:
        return PairAcceptedMessage.fromJson(body);
      case ControlMessageType.pairRejected:
        return PairRejectedMessage.fromJson(body);
      case ControlMessageType.pinPairingInit:
        return PinPairingInitMessage.fromJson(body);
      case ControlMessageType.pinRequired:
        return PinRequiredMessage.fromJson(body);
      case ControlMessageType.pinSubmit:
        return PinSubmitMessage.fromJson(body);
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
    }
  }
}
