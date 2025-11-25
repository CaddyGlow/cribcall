import 'dart:convert';

String encodePem(String label, List<int> derBytes) {
  final b64 = base64.encode(derBytes);
  final buffer = StringBuffer()..writeln('-----BEGIN $label-----');
  for (var i = 0; i < b64.length; i += 64) {
    final end = (i + 64 < b64.length) ? i + 64 : b64.length;
    buffer.writeln(b64.substring(i, end));
  }
  buffer
    ..writeln('-----END $label-----')
    ..write('\n');
  return buffer.toString();
}
