import 'dart:convert';
import 'dart:typed_data';

// Internal formatting only: no reflection, native access, or payload decoding.
String mqttDebugString(String type, Map<String, Object?> fields) =>
    '$type(${fields.entries.map((e) => '${e.key}: ${_value(e.value)}').join(', ')})';

String _value(Object? value) {
  if (value is Uint8List) return '<${value.length} bytes>';
  if (value is String) {
    const limit = 256;
    return jsonEncode(value.length <= limit
        ? value
        : '${value.substring(0, limit)}… (${value.length} chars)');
  }
  if (value is List) {
    final preview = value.take(8).map(_value).join(', ');
    return '[$preview${value.length > 8 ? ', … (${value.length} items)' : ''}]';
  }
  return '$value';
}

String? mqttDebugSecret(Object? value) => value == null ? null : '<redacted>';

// Broker URLs sometimes contain credentials or query tokens.
String mqttDebugServerUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme || !uri.hasAuthority)
    return '<invalid URI>';
  return Uri(
          scheme: uri.scheme,
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
          path: uri.path)
      .toString();
}
