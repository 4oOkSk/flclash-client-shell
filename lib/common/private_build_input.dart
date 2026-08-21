import 'dart:convert';

/// Prevents a plain API hostname from being recoverable with a basic strings
/// scan. This is build-time obfuscation, not a security or authentication
/// boundary; a runtime observer can still discover the destination.
String encodePrivateClientApiBase(String value) {
  if (value.isEmpty) return '';
  final transformed = utf8
      .encode(value)
      .reversed
      .map((byte) => byte ^ 0xa5)
      .toList(growable: false);
  return base64Url.encode(transformed).replaceAll('=', '');
}

String decodePrivateClientApiBase(String value) {
  if (value.isEmpty) return '';
  try {
    final decoded = base64Url
        .decode(base64Url.normalize(value))
        .map((byte) => byte ^ 0xa5)
        .toList(growable: false)
        .reversed
        .toList(growable: false);
    return utf8.decode(decoded);
  } catch (_) {
    return '';
  }
}
