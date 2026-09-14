import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/diagnostic_journal.dart';
import 'package:fl_clash/common/diagnostic_upload.dart';
import 'package:fl_clash/models/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late DiagnosticJournal journal;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('diagnostic-test-');
    journal = DiagnosticJournal(byteLimit: 4096);
    await journal.open(directory);
  });
  tearDown(() async {
    await journal.close();
    await directory.delete(recursive: true);
  });

  test('retains safe messages and correlates visited connections', () async {
    journal.observe(
      '[DNS] c2c.cdn.weixin.qq.com --> 203.0.113.9',
      source: 'core',
      coreSanitized: true,
    );
    final tracker = TrackerInfo(
      id: 'a-core-connection-id',
      start: DateTime.now(),
      metadata: const Metadata(
        network: 'udp',
        host: 'c2c.cdn.weixin.qq.com',
        destinationPort: '443',
      ),
      chains: const ['private-node'],
      rule: 'MATCH',
      rulePayload: '',
      lifecycle: 'active',
      diagnosticRoute: 'proxy',
      diagnosticRule: 'match',
      diagnosticPolicy: 'fallback',
    );
    journal.request(tracker);
    journal.request(
      tracker.copyWith(
        lifecycle: 'closed',
        endReason: 'no-response',
        durationMs: 30000,
        upload: 162,
      ),
    );
    journal.request(tracker.copyWith(diagnosticDestination: 'server-endpoint'));
    journal.request(
      tracker.copyWith(metadata: tracker.metadata.copyWith(type: 'Inner')),
    );
    journal.observe(
      'VpnService TUN core started',
      source: 'platform',
      historical: true,
    );
    final text = utf8.decode(await journal.snapshot());
    final records = const LineSplitter()
        .convert(text)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
    final requests = records
        .where((record) => record['event'] == 'request')
        .toList();
    expect(requests, hasLength(3));
    expect(requests[0]['connectionId'], requests[1]['connectionId']);
    expect(requests[0]['destination'], 'c2c.cdn.weixin.qq.com:443');
    expect(requests[1]['result'], 'no-response');
    expect(requests[2]['destination'], '[server-endpoint]');
    expect(records.first['message'], contains('203.0.113.9'));
    expect(records.last['historical'], isTrue);
    expect(text, isNot(contains('private-node')));
    expect(text, isNot(contains('a-core-connection-id')));
    expect(DiagnosticJournal.validBytes(utf8.encode(text)), isTrue);
    expect(
      DiagnosticJournal.accepts(
        'destination',
        'https://subscription.example/token',
      ),
      isFalse,
    );
    expect(DiagnosticJournal.accepts('message', 'password=secret'), isFalse);
    expect(DiagnosticJournal.accepts('connectionId', 'node.example'), isFalse);
  });

  test('secrets never reach disk and rotated storage stays bounded', () async {
    for (var index = 0; index < 100; index++) {
      journal.observe(
        'https://subscription.example/token password=secret-value server=node.example:8443 connect failed',
      );
      journal.record('request', {
        'source': 'node.example',
        'port': 8443,
        'uploadBytes': 'secret-value',
        'route': 'proxy',
        'durationMs': index,
      });
      if (index % 10 == 0) await journal.flush();
    }
    final bytes = await journal.snapshot();
    expect(bytes.length, lessThanOrEqualTo(4096));
    final text = utf8.decode(bytes);
    for (final secret in [
      'subscription.example',
      'token',
      'secret-value',
      'node.example',
      '8443',
    ]) {
      expect(text, isNot(contains(secret)));
    }
    expect(
      const LineSplitter().convert(text).every(DiagnosticJournal.validLine),
      isTrue,
    );
    final files = await directory.list().toList();
    expect(files.length, lessThanOrEqualTo(4));
    final lengths = await Future.wait(
      files.cast<File>().map((file) => file.length()),
    );
    expect(
      lengths.fold<int>(0, (total, value) => total + value),
      lessThanOrEqualTo(4096),
    );
  });

  test(
    'large snapshots validate off-thread and upload in complete-line chunks',
    () async {
      final large = DiagnosticJournal();
      await large.open(Directory('${directory.path}/large'));
      for (var index = 0; index < 8000; index++) {
        large.record('request', {'route': 'proxy', 'durationMs': index});
        if (index % 400 == 0) await large.flush();
      }
      final bytes = await large.snapshot();
      expect(bytes.length, greaterThan(512 * 1024));
      var received = 0;
      var chunks = 0;
      final upload = DiagnosticUpload((body) async {
        switch (body['action']) {
          case 'begin':
            return jsonEncode({'ret': 1, 'id': 'b' * 32});
          case 'chunk':
            final chunk = base64Decode(body['data'] as String);
            expect(body['offset'], received);
            expect(chunk.length, lessThanOrEqualTo(256 * 1024));
            expect(chunk.last, 10);
            expect(DiagnosticJournal.validBytes(chunk), isTrue);
            received += chunk.length;
            chunks++;
          case 'status':
            return '{"ret":1,"state":"ready","url":"https://logs.example/files/harborproxylogs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jsonl"}';
        }
        return '{"ret":1}';
      }, wait: (_) async {});
      await upload.upload(bytes);
      expect(received, bytes.length);
      expect(chunks, greaterThan(2));
      await large.close();
    },
  );

  test('rejects an unsafe on-disk record before export', () async {
    expect(
      DiagnosticJournal.validLine(
        '{"time":"2026-09-14T00:00:00.000Z","elapsedMs":0,"event":"startup","source":"secret.example","source":"app"}',
      ),
      isFalse,
    );
    await File(
      '${directory.path}/client-0.jsonl',
    ).writeAsString('password=secret\n');
    await expectLater(journal.snapshot(), throwsFormatException);
  });

  test(
    'upload preserves bytes and accepts only a private report URL shape',
    () async {
      journal.record('startup', {'result': 'begin'});
      final bytes = await journal.snapshot();
      final received = <int>[];
      final upload = DiagnosticUpload((body) async {
        switch (body['action']) {
          case 'begin':
            return jsonEncode({'ret': 1, 'id': 'a' * 32});
          case 'chunk':
            received.addAll(base64Decode(body['data'] as String));
          case 'status':
            return jsonEncode({
              'ret': 1,
              'state': 'ready',
              'url':
                  'https://logs.example/files/harborproxylogs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jsonl',
            });
        }
        return '{"ret":1}';
      }, wait: (_) async {});
      expect(
        await upload.upload(bytes),
        'https://logs.example/files/harborproxylogs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jsonl',
      );
      expect(received, bytes);
    },
  );

  test(
    'cancel stops further requests; login failures are not retried',
    () async {
      journal.record('startup');
      final bytes = await journal.snapshot();
      var calls = 0;
      final upload = DiagnosticUpload((_) async {
        calls++;
        return '{"ret":0,"error":"login-required"}';
      }, wait: (_) async {});
      await expectLater(
        upload.upload(bytes),
        throwsA(isA<DiagnosticUploadException>()),
      );
      expect(calls, 1);
      upload.cancelled = true;
      await expectLater(
        upload.upload(bytes),
        throwsA(isA<DiagnosticUploadException>()),
      );
      expect(calls, 1);
    },
  );
}
