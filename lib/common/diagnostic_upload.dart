import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'diagnostic_journal.dart';

typedef DiagnosticRequest =
    Future<String> Function(Map<String, Object?> request);

class DiagnosticUploadException implements Exception {
  final String code;
  const DiagnosticUploadException(this.code);
}

String _diagnosticDigest(List<int> bytes) {
  if (!DiagnosticJournal.validBytes(bytes)) {
    throw const DiagnosticUploadException('invalid');
  }
  return sha256.convert(bytes).toString();
}

Future<String> _computeDiagnosticDigest(List<int> bytes) =>
    Isolate.run(() => _diagnosticDigest(bytes));

class DiagnosticUpload {
  final DiagnosticRequest request;
  final Future<void> Function(Duration) wait;
  bool cancelled = false;

  DiagnosticUpload(this.request, {this.wait = Future<void>.delayed});

  Future<Map<String, dynamic>> _send(Map<String, Object?> body) async {
    if (cancelled) throw const DiagnosticUploadException('cancelled');
    Map<String, dynamic>? result;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final decoded = jsonDecode(await request(body));
        if (decoded is Map<String, dynamic>) result = decoded;
      } catch (_) {}
      if (cancelled) throw const DiagnosticUploadException('cancelled');
      if (result?['ret'] == 1) return result!;
      if (result?['error'] == 'login-required' ||
          result?['error'] == 'rate-limited' ||
          result?['error'] == 'invalid') {
        break;
      }
      if (attempt == 0) await wait(const Duration(seconds: 2));
    }
    throw DiagnosticUploadException(switch (result?['error']) {
      'login-required' => 'login-required',
      'rate-limited' => 'rate-limited',
      _ => 'unavailable',
    });
  }

  Future<String> upload(
    List<int> bytes, {
    void Function(double)? progress,
  }) async {
    if (bytes.isEmpty || bytes.length > diagnosticJournalBytes) {
      throw const DiagnosticUploadException('invalid');
    }
    final digest = bytes.length > 512 * 1024
        ? await _computeDiagnosticDigest(bytes)
        : _diagnosticDigest(bytes);
    final random = Random.secure();
    final nonce = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final start = await _send({
      'action': 'begin',
      'nonce': nonce,
      'bytes': bytes.length,
      'sha256': digest,
    });
    final id = start['id'];
    if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw const DiagnosticUploadException('invalid');
    }
    try {
      const chunkBytes = 256 * 1024;
      for (var offset = 0; offset < bytes.length;) {
        var end = min(offset + chunkBytes, bytes.length);
        while (end > offset && bytes[end - 1] != 10) {
          end--;
        }
        if (end == offset) throw const DiagnosticUploadException('invalid');
        await _send({
          'action': 'chunk',
          'id': id,
          'offset': offset,
          'data': base64Encode(bytes.sublist(offset, end)),
        });
        progress?.call(end / bytes.length);
        offset = end;
      }
      await _send({'action': 'finish', 'id': id});
      for (var attempt = 0; attempt < 90; attempt++) {
        final status = await _send({'action': 'status', 'id': id});
        if (status['state'] == 'failed') {
          throw const DiagnosticUploadException('unavailable');
        }
        if (status['state'] == 'ready') {
          final url = status['url'];
          if (url is String &&
              RegExp(
                r'^https://gitlab\.com/[A-Za-z0-9_./-]+/-/snippets/[0-9]+$',
              ).hasMatch(url)) {
            return url;
          }
          throw const DiagnosticUploadException('invalid');
        }
        await wait(const Duration(seconds: 2));
      }
      throw const DiagnosticUploadException('timeout');
    } finally {
      if (cancelled) {
        try {
          await request({'action': 'cancel', 'id': id});
        } catch (_) {}
      }
    }
  }
}
