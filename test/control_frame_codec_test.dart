import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:cribcall/src/control/control_frame_codec.dart';

void main() {
  test('encodes and decodes length-prefixed control frames', () {
    final message = {'type': 'PING', 'timestamp': 123};

    final frame = ControlFrameCodec.encodeJson(message);
    final decoder = ControlFrameDecoder();

    final chunk1 = frame.sublist(0, 5);
    final chunk2 = frame.sublist(5);

    expect(decoder.addChunkAndDecodeJson(chunk1), isEmpty);

    final decoded = decoder.addChunkAndDecodeJson(chunk2);
    expect(decoded.single, equals(message));
  });

  test('throws when frame length exceeds limit', () {
    final decoder = ControlFrameDecoder(maxFrameLength: 8);
    final payload = Uint8List.fromList(List.filled(16, 1));
    final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
    final oversized = <int>[...header.buffer.asUint8List(), ...payload];

    expect(() => decoder.addChunk(oversized), throwsFormatException);
  });

  test('throws when payload is not a JSON object', () {
    final frame = ControlFrameCodec.encodeBytes(
      Uint8List.fromList(utf8.encode('"oops"')),
    );
    final decoder = ControlFrameDecoder();

    expect(() => decoder.addChunkAndDecodeJson(frame), throwsFormatException);
  });
}
