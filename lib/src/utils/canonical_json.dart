import 'dart:convert';

import 'package:canonical_json/canonical_json.dart';

String canonicalizeJson(Map<String, dynamic> value) {
  final bytes = canonicalJson.encode(value);
  return utf8.decode(bytes);
}

List<int> canonicalizeToBytes(Map<String, dynamic> value) {
  return canonicalJson.encode(value);
}
