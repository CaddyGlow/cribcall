import 'dart:convert';

import 'package:crypto/crypto.dart';

String computeHmacSha256({
  required List<int> key,
  required List<int> message,
}) {
  final hmac = Hmac(sha256, key);
  final digest = hmac.convert(message);
  return base64Encode(digest.bytes);
}
