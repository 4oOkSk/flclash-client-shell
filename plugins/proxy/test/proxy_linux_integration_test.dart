import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy/proxy.dart';
import 'package:proxy/src/linux_proxy.dart';
import 'package:proxy/src/proxy_command.dart';

void main() {
  final enabled =
      Platform.isLinux &&
      Platform.environment['HARBORPROXY_LINUX_PROXY_INTEGRATION'] == '1';

  test('writes and clears GNOME system proxy settings', () async {
    final proxy = Proxy();
    try {
      expect(await proxy.startProxy(17891, ['localhost']), isTrue);
      expect(await _gsettings('org.gnome.system.proxy', 'mode'), "'manual'");
      expect(
        await _gsettings('org.gnome.system.proxy.http', 'host'),
        "'127.0.0.1'",
      );
      expect(await _gsettings('org.gnome.system.proxy.http', 'port'), '17891');
    } finally {
      expect(await proxy.stopProxy(), isTrue);
    }
    expect(await _gsettings('org.gnome.system.proxy', 'mode'), "'none'");
  }, skip: !enabled);

  test('rolls back partial GNOME settings when a write fails', () async {
    final calls = <List<String>>[];
    final original = <String, String>{
      'org.gnome.system.proxy/mode': "'none'",
      'org.gnome.system.proxy/ignore-hosts': '[]',
      for (final kind in ['http', 'https', 'socks']) ...{
        'org.gnome.system.proxy.$kind/host': "''",
        'org.gnome.system.proxy.$kind/port': '0',
      },
    };
    final state = Map<String, String>.from(original);
    var failedWrite = false;
    final proxy = LinuxProxy(
      executableChecker: (_) async => true,
      commandRunner: ProxyCommandRunner((
        executable,
        arguments, {
        runInShell = false,
      }) async {
        calls.add([executable, ...arguments]);
        final key = '${arguments[1]}/${arguments[2]}';
        if (arguments[0] == 'get') {
          return ProcessResult(1, 0, '${state[key]}\n', '');
        }
        if (!failedWrite &&
            key == 'org.gnome.system.proxy.https/host' &&
            arguments[3] == '127.0.0.1') {
          failedWrite = true;
          return ProcessResult(1, 1, '', 'injected write failure');
        }
        var value = arguments[3];
        if (['mode', 'host'].contains(arguments[2]) && !value.startsWith("'")) {
          value = "'$value'";
        }
        state[key] = value;
        return ProcessResult(1, 0, '', '');
      }),
    );

    expect(
      await proxy.start(17891, [], desktop: 'GNOME', homeDir: '/home/test'),
      isFalse,
    );
    expect(failedWrite, isTrue);
    expect(state, original);
    expect(calls.where((call) => call[1] == 'set').last, [
      'gsettings',
      'set',
      'org.gnome.system.proxy.http',
      'port',
      '0',
    ]);
    // The failed host write precedes enabling manual mode; rollback restores
    // the partial endpoint, not a control switch that was never changed.
    expect(
      calls.where((call) => call[1] == 'set' && call[3] == 'mode'),
      isEmpty,
    );
  });
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
