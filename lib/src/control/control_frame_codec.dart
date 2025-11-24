import 'dart:convert';
import 'dart:typed_data';

class ControlFrameCodec {
  static const int maxFrameLength = 512000;

  static Uint8List encodeJson(Map<String, dynamic> json) {
    final payload = utf8.encode(jsonEncode(json));
    return encodeBytes(Uint8List.fromList(payload));
  }

  static Uint8List encodeBytes(Uint8List payload) {
    final header = ByteData(4)..setUint32(0, payload.length, Endian.big);
    return Uint8List.fromList(header.buffer.asUint8List() + payload);
  }
}

class ControlFrameDecoder {
  ControlFrameDecoder({this.maxFrameLength = ControlFrameCodec.maxFrameLength});

  final int maxFrameLength;
  final List<int> _buffer = [];

  List<Uint8List> addChunk(List<int> chunk) {
    _buffer.addAll(chunk);
    final frames = <Uint8List>[];

    while (_buffer.length >= 4) {
      final lengthBytes = Uint8List.fromList(_buffer.sublist(0, 4));
      final length = ByteData.sublistView(lengthBytes).getUint32(0, Endian.big);
      if (length > maxFrameLength) {
        throw const FormatException('Frame exceeds maximum length');
      }
      if (_buffer.length < 4 + length) {
        break;
      }

      final payload = Uint8List.fromList(_buffer.sublist(4, 4 + length));
      frames.add(payload);
      _buffer.removeRange(0, 4 + length);
    }

    return frames;
  }

  List<Map<String, dynamic>> addChunkAndDecodeJson(List<int> chunk) {
    final payloads = addChunk(chunk);
    return payloads.map((p) {
      final decoded = jsonDecode(utf8.decode(p));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Control frame did not contain JSON object',
        );
      }
      return decoded;
    }).toList();
  }
}
