import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy/proxy.dart';

void main() {
  final enabled = Platform.isLinux &&
      Platform.environment['HARBORPROXY_LINUX_PROXY_INTEGRATION'] == '1';

  test(
    'writes and clears GNOME system proxy settings',
    () async {
      final proxy = Proxy();
      try {
        expect(await proxy.startProxy(17891, ['localhost']), isTrue);
        expect(await _gsettings('org.gnome.system.proxy', 'mode'), "'manual'");
        expect(
          await _gsettings('org.gnome.system.proxy.http', 'host'),
          "'127.0.0.1'",
        );
        expect(
            await _gsettings('org.gnome.system.proxy.http', 'port'), '17891');
      } finally {
        expect(await proxy.stopProxy(), isTrue);
      }
      expect(await _gsettings('org.gnome.system.proxy', 'mode'), "'none'");
    },
    skip: !enabled,
  );

  test(
    'rolls back GNOME proxy mode when a write fails',
    () async {
      final calls = <List<String>>[];
      final proxy = Proxy(
        executableChecker: (_) async => true,
        processRunner: (
          executable,
          arguments, {
          runInShell = false,
        }) async {
          calls.add([executable, ...arguments]);
          final shouldFail = arguments.any((arg) => arg.endsWith('.https')) &&
              arguments.contains('host');
          return ProcessResult(1, shouldFail ? 1 : 0, '', '');
        },
      );

      expect(await proxy.startProxy(17891), isFalse);
      expect(
        calls.last,
        ['gsettings', 'set', 'org.gnome.system.proxy', 'mode', 'none'],
      );
    },
    skip: !enabled,
  );
}

Future<String> _gsettings(String schema, String key) async {
  final result = await Process.run('gsettings', ['get', schema, key]);
  if (result.exitCode != 0) {
    throw ProcessException(
      'gsettings',
      ['get', schema, key],
      result.stderr.toString(),
      result.exitCode,
    );
  }
  return result.stdout.toString().trim();
}
