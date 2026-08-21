import 'dart:convert';

class PrivateClientAccountInfo {
  final int remainingBytes;
  final int expireAt;

  const PrivateClientAccountInfo({
    required this.remainingBytes,
    required this.expireAt,
  });

  static PrivateClientAccountInfo? tryParse(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      final remaining = json['remaining_bytes'];
      final expire = json['expire_at'];
      if (remaining is! num || expire is! num) return null;
      final remainingBytes = remaining.toInt();
      final expireAt = expire.toInt();
      if (remainingBytes < 0 || expireAt < 0) return null;
      return PrivateClientAccountInfo(
        remainingBytes: remainingBytes,
        expireAt: expireAt,
      );
    } catch (_) {
      return null;
    }
  }
}
