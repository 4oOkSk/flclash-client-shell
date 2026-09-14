import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/diagnostic_log.dart';
import 'package:fl_clash/models/common.dart';

const diagnosticJournalBytes = 20 * 1024 * 1024;

Future<bool> _validateDiagnosticBytes(List<int> bytes) =>
    Isolate.run(() => DiagnosticJournal.validBytes(bytes));
const diagnosticJournalEvents = {
  'startup',
  'ready',
  'shutdown',
  'login',
  'refresh',
  'configuration',
  'selection',
  'routing',
  'connect',
  'disconnect',
  'vpn',
  'network',
  'lifecycle',
  'dns',
  'tls',
  'request',
  'core',
  'upload',
  'storage',
  'error',
  'noise',
  'status',
  'export',
  'navigation',
};
const diagnosticJournalValues = {
  'app',
  'core',
  'platform',
  'info',
  'warning',
  'error',
  'debug',
  'begin',
  'success',
  'failed',
  'cancelled',
  'timeout',
  'refused',
  'reset',
  'unreachable',
  'other',
  'active',
  'closed',
  'tcp',
  'udp',
  'direct',
  'proxy',
  'reject',
  'unknown',
  'connected',
  'disconnected',
  'connecting',
  'disconnecting',
  'resumed',
  'inactive',
  'hidden',
  'paused',
  'detached',
  'bypass-mainland',
  'bypass-overseas',
  'global',
  'pending',
  'applied',
  'manual',
  'automatic',
  'eof',
  'no-response',
  'io-error',
  'android',
  'windows',
  'linux',
  'macos',
  'home',
  'servers',
  'rules',
  'account',
  'applying',
  'restored',
  'idle',
  'idle-timeout',
  'domain',
  'ip',
  'rule-set',
  'match',
  'transport',
  'process',
  'none',
  'private',
  'ipv6-block',
  'probe',
  'overseas-service',
  'overseas-domain',
  'mainland-domain',
  'mainland-ip',
  'fallback',
  'local',
};
const diagnosticJournalFields = {
  'source',
  'level',
  'result',
  'phase',
  'mode',
  'network',
  'route',
  'durationMs',
  'uploadBytes',
  'downloadBytes',
  'count',
  'build',
  'active',
  'tun',
  'tunRequested',
  'session',
  'platform',
  'page',
  'ipv6',
  'dnsCompleted',
  'dnsFailed',
  'protectFailures',
  'runId',
  'connectionId',
  'destination',
  'rule',
  'policy',
  'message',
  'historical',
};

final _journalUnsafeText = RegExp(
  r'[\x00-\x1f\x7f]|[a-zA-Z][a-zA-Z0-9+.-]*://|'
  r'\b(?:password|passwd|token|authorization|cookie|uuid|server|port|sni|private-key|public-key|short-id)\s*["\x27]?\s*[:=]\s*(?!\[)',
  caseSensitive: false,
);

String _journalMessage(String value, bool coreSanitized) {
  var message = coreSanitized ? value : sanitizeDiagnosticLog(value);
  message = message.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
  if (_journalUnsafeText.hasMatch(message)) {
    message = sanitizeDiagnosticLog(message);
  }
  return String.fromCharCodes(message.runes.take(320));
}

class DiagnosticJournal {
  final int byteLimit;
  final Stopwatch _clock = Stopwatch()..start();
  final List<String> _pending = [];
  final String _runId = List.generate(
    8,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  Directory? _directory;
  Timer? _timer;
  Future<void> _work = Future.value();
  int _dropped = 0;
  bool _closed = false;
  bool storageFailed = false;

  DiagnosticJournal({this.byteLimit = diagnosticJournalBytes}) {
    if (byteLimit < 4096 || byteLimit > diagnosticJournalBytes) {
      throw ArgumentError.value(byteLimit);
    }
  }

  static bool accepts(String key, Object? value) {
    if (!diagnosticJournalFields.contains(key)) return false;
    if (key == 'runId' || key == 'connectionId') {
      return value is String && RegExp(r'^[0-9a-f]{16}$').hasMatch(value);
    }
    if (key == 'destination') {
      return value is String &&
          !value.contains('://') &&
          sanitizeVisitedDestination(value) == value;
    }
    if (key == 'message') {
      return value is String &&
          utf8.encode(value).length <= 1280 &&
          !_journalUnsafeText.hasMatch(value);
    }
    if (const {
      'active',
      'tun',
      'tunRequested',
      'session',
      'ipv6',
      'historical',
    }.contains(key)) {
      return value is bool;
    }
    if (const {
      'durationMs',
      'uploadBytes',
      'downloadBytes',
      'count',
      'build',
      'dnsCompleted',
      'dnsFailed',
      'protectFailures',
    }.contains(key)) {
      return value is int && value >= 0 && value <= 9007199254740991;
    }
    return value is String && diagnosticJournalValues.contains(value);
  }

  static bool validLine(String line) {
    if (utf8.encode(line).length > 4096) return false;
    try {
      final data = jsonDecode(line);
      if (jsonEncode(data) != line) return false;
      if (data is! Map<String, dynamic> ||
          !diagnosticJournalEvents.contains(data['event']) ||
          data['time'] is! String ||
          !RegExp(
            r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3,6}Z$',
          ).hasMatch(data['time']) ||
          data['elapsedMs'] is! int ||
          data['elapsedMs'] < 0 ||
          data['elapsedMs'] > 9007199254740991) {
        return false;
      }
      return data.entries.every(
        (entry) =>
            const {'time', 'elapsedMs', 'event'}.contains(entry.key) ||
            accepts(entry.key, entry.value),
      );
    } catch (_) {
      return false;
    }
  }

  static bool validBytes(List<int> bytes) =>
      const LineSplitter().convert(utf8.decode(bytes)).every(validLine);

  void record(String event, [Map<String, Object?> fields = const {}]) {
    if (_closed || !diagnosticJournalEvents.contains(event)) return;
    final safe = <String, Object?>{};
    for (final entry in fields.entries) {
      final value = entry.value;
      if (accepts(entry.key, value)) {
        safe[entry.key] = value;
      }
    }
    if (_pending.length >= 512) {
      _dropped++;
      return;
    }
    _pending.add(
      jsonEncode({
        'time': DateTime.now().toUtc().toIso8601String(),
        'elapsedMs': _clock.elapsedMilliseconds,
        'runId': _runId,
        'event': event,
        ...safe,
      }),
    );
  }

  void observe(
    String message, {
    String source = 'app',
    String level = 'info',
    bool coreSanitized = false,
    bool historical = false,
  }) {
    final text = message.toLowerCase();
    final event = switch (text) {
      _ when text.contains('updategroups') || text.contains('find http') =>
        'noise',
      _ when text.contains('login') || text.contains('session') => 'login',
      _ when text.contains('disconnect') || text.contains('stopping') =>
        'disconnect',
      _ when text.contains('vpn') || text.contains('tun ') => 'vpn',
      _ when text.contains('dns') => 'dns',
      _ when text.contains('tls') || text.contains('certificate') => 'tls',
      _ when text.contains('connectivity') || text.contains('checkip') =>
        'network',
      _ when text.contains('lifecycle') || text.contains('destination=') =>
        'lifecycle',
      _ when text.contains('config') || text.contains('geosite') =>
        'configuration',
      _ when text.contains('proxy') || text.contains('select') => 'selection',
      _ when text.contains('connect') => 'connect',
      _ => 'core',
    };
    if (event == 'noise') {
      _dropped++;
      return;
    }
    final result = switch (text) {
      _ when text.contains('timeout') || text.contains('timed out') =>
        'timeout',
      _ when text.contains('refused') => 'refused',
      _ when text.contains('reset') => 'reset',
      _ when text.contains('unreachable') => 'unreachable',
      _ when text.contains('fail') || text.contains('error') => 'failed',
      _
          when text.contains('success') ||
              text.contains('complete') ||
              text.contains('established') =>
        'success',
      _ when text.contains('cancel') => 'cancelled',
      _ when text.contains('start') => 'begin',
      _ => 'other',
    };
    final phase = const ['resumed', 'inactive', 'hidden', 'paused', 'detached']
        .where(
          (value) =>
              text.contains('app lifecyclestate.$value') ||
              text.contains('applifecyclestate.$value'),
        )
        .firstOrNull;
    record(event, {
      'source': source,
      'level': level,
      'result': result,
      'phase': ?phase,
      'message': _journalMessage(message, coreSanitized),
      if (historical) 'historical': true,
    });
  }

  void request(TrackerInfo tracker) {
    if (tracker.metadata.type.toLowerCase() == 'inner') return;
    record('request', {
      'source': 'core',
      if (tracker.id.isNotEmpty)
        'connectionId': sha256
            .convert(utf8.encode('$_runId:${tracker.id}'))
            .toString()
            .substring(0, 16),
      'destination': trackerVisitedDestination(tracker),
      'phase': tracker.lifecycle,
      'network': tracker.metadata.network.toLowerCase(),
      'route': tracker.diagnosticRoute,
      'rule': tracker.diagnosticRule,
      'policy': tracker.diagnosticPolicy,
      'result': tracker.endReason,
      'durationMs': tracker.durationMs,
      'uploadBytes': tracker.upload,
      'downloadBytes': tracker.download,
    });
  }

  Future<void> open(Directory directory) async {
    _directory = directory;
    try {
      await directory.create(recursive: true);
      if (!Platform.isWindows) {
        final permission = await Process.run('chmod', ['700', directory.path]);
        if (permission.exitCode != 0) throw const FileSystemException();
      }
      await flush();
      _timer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(flush()),
      );
    } catch (_) {
      storageFailed = true;
    }
  }

  Future<void> flush() {
    _work = _work
        .then((_) async {
          final directory = _directory;
          if (directory == null || (_pending.isEmpty && _dropped == 0)) return;
          final lines = List<String>.of(_pending);
          _pending.clear();
          if (_dropped > 0) {
            lines.add(
              jsonEncode({
                'time': DateTime.now().toUtc().toIso8601String(),
                'elapsedMs': _clock.elapsedMilliseconds,
                'event': 'noise',
                'count': _dropped,
              }),
            );
            _dropped = 0;
          }
          var chunks = <int>[];
          for (final line in lines) {
            final bytes = utf8.encode('$line\n');
            if (chunks.length + bytes.length > byteLimit ~/ 4) {
              await _append(chunks, directory);
              chunks = <int>[];
            }
            chunks.addAll(bytes);
          }
          if (chunks.isNotEmpty) await _append(chunks, directory);
          storageFailed = false;
        })
        .catchError((Object _) {
          storageFailed = true;
        });
    return _work;
  }

  Future<void> _append(List<int> chunk, Directory directory) async {
    final current = File('${directory.path}/client-0.jsonl');
    if (await current.exists() &&
        await current.length() + chunk.length > byteLimit ~/ 4) {
      final oldest = File('${directory.path}/client-3.jsonl');
      if (await oldest.exists()) await oldest.delete();
      for (var index = 2; index >= 0; index--) {
        final file = File('${directory.path}/client-$index.jsonl');
        if (await file.exists()) {
          await file.rename('${directory.path}/client-${index + 1}.jsonl');
        }
      }
    }
    final created = !await current.exists();
    await current.writeAsBytes(chunk, mode: FileMode.append, flush: true);
    if (created && !Platform.isWindows) {
      final permission = await Process.run('chmod', ['600', current.path]);
      if (permission.exitCode != 0) throw const FileSystemException();
    }
  }

  Future<List<int>> snapshot() async {
    await flush();
    final snapshot = _work.then((_) async {
      if (storageFailed || _directory == null) {
        throw const FileSystemException();
      }
      final result = BytesBuilder(copy: false);
      for (var index = 3; index >= 0; index--) {
        final file = File('${_directory!.path}/client-$index.jsonl');
        if (!await file.exists()) continue;
        if (result.length + await file.length() > byteLimit) {
          throw const FileSystemException();
        }
        final bytes = await file.readAsBytes();
        final valid = bytes.length > 512 * 1024
            ? await _validateDiagnosticBytes(bytes)
            : validBytes(bytes);
        if (!valid) {
          throw const FormatException('invalid diagnostic schema');
        }
        result.add(bytes);
      }
      return result.takeBytes();
    });
    _work = snapshot.then<void>((_) {}, onError: (Object _) {});
    return snapshot;
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    await flush();
  }
}

final diagnosticJournal = DiagnosticJournal();
