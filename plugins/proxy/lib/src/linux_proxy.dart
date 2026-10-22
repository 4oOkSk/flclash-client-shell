import 'dart:io';

import 'package:path/path.dart' as path;

import 'proxy_command.dart';
import 'proxy_ownership.dart';

enum LinuxProxyBackend { gnome, mate, kde }

enum _ProxyType { http, https, socks }

class LinuxProxy {
  final ProxyCommandRunner _commandRunner;
  final ProxyExecutableChecker _executableChecker;
  final ProxyOwnershipStore _ownership;

  LinuxProxy({
    required ProxyCommandRunner commandRunner,
    ProxyExecutableChecker? executableChecker,
    ProxyOwnershipStore? ownership,
  }) : _commandRunner = commandRunner,
       _ownership = ownership ?? ProxyOwnershipStore(),
       _executableChecker = executableChecker ?? _hasExecutable;

  Future<bool> start(
    int port,
    List<String> bypassDomain, {
    required String? desktop,
    required String? homeDir,
  }) async {
    if (homeDir == null || homeDir.isEmpty) {
      return false;
    }
    final selection = await _resolveBackend(desktop);
    if (selection == null) {
      return false;
    }
    if (!await stop(desktop: desktop, homeDir: homeDir)) return false;
    try {
      final commands = LinuxProxyCommands.buildStartForBackend(
        port: port,
        bypassDomain: bypassDomain,
        homeDir: homeDir,
        backend: selection.backend,
        kdeConfigWriter: selection.executable,
      );
      final entries = <Map<String, dynamic>>[];
      for (final command in commands) {
        final gsettings = command.executable == 'gsettings';
        final args = command.args;
        final read = gsettings
            ? ['get', args[1], args[2]]
            : [...args.take(args.length - 1), '--default', _absent];
        final reader = gsettings
            ? 'gsettings'
            : command.executable.replaceFirst('kwrite', 'kread');
        var expected = args.last;
        if (gsettings && (args[2] == 'host' || args[2] == 'mode')) {
          expected = "'$expected'";
        }
        entries.add({
          'reader': reader,
          'read': read,
          'writer': command.executable,
          'write': args.take(args.length - 1).toList(),
          'group': gsettings ? args[1] : args[5],
          'control': gsettings ? args[2] == 'mode' : args[5] == 'ProxyType',
          'original': await _readValue(reader, read),
          'applied': _normalize(expected),
        });
      }
      await _ownership.write({'platform': 'linux', 'entries': entries});
      if (!await _commandRunner.run(commands)) {
        await stop(desktop: desktop, homeDir: homeDir);
        return false;
      }
      for (final entry in entries) {
        if (await _readEntry(entry) != entry['applied']) {
          await stop(desktop: desktop, homeDir: homeDir);
          return false;
        }
      }
      return true;
    } on Object {
      await stop(desktop: desktop, homeDir: homeDir);
      return false;
    }
  }

  Future<bool> stop({
    required String? desktop,
    required String? homeDir,
  }) async {
    try {
      final journal = await _ownership.read();
      if (journal.isEmpty) return true;
      if (journal['platform'] != 'linux') return false;
      final entries = (journal['entries'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final current = [for (final entry in entries) await _readEntry(entry)];
      bool unchanged(int i) =>
          current[i] == entries[i]['applied'] ||
          current[i] == entries[i]['original'];
      final restored = <int>[];
      // Restore the control switch last, and only if no endpoint was replaced externally.
      for (final control in [false, true]) {
        for (var i = 0; i < entries.length; i++) {
          final entry = entries[i];
          if (entry['control'] != control ||
              current[i] != entry['applied'] ||
              current[i] == entry['original']) {
            continue;
          }
          final safe = control
              ? List.generate(
                  entries.length,
                  (i) => i,
                ).where((j) => entries[j]['control'] != true).every(unchanged)
              : List.generate(entries.length, (i) => i)
                    .where((j) => entries[j]['group'] == entry['group'])
                    .every(unchanged);
          if (!safe) continue;
          final args = List<String>.from(entry['write'] as List);
          if (entry['original'] == _absent) {
            args.add('--delete');
          } else {
            args.add(entry['original'] as String);
          }
          if (!await _commandRunner.run([
            ProxyCommand(entry['writer'] as String, args),
          ])) {
            return false;
          }
          restored.add(i);
        }
      }
      for (final i in restored) {
        if (await _readEntry(entries[i]) != entries[i]['original']) {
          return false;
        }
      }
      await _ownership.write({});
      return true;
    } on Object {
      return false;
    }
  }

  static const _absent = '__harborproxy_absent_proxy_key__';
  static String _normalize(String value) =>
      value.trim().replaceFirst(RegExp(r'^@as\s+'), '');
  Future<String> _readValue(String executable, List<String> args) async {
    final result = await _commandRunner.process(executable, args);
    if (result.exitCode != 0) {
      throw const FormatException('Unable to read system proxy');
    }
    return _normalize(result.stdout.toString());
  }

  Future<String> _readEntry(Map<String, dynamic> entry) => _readValue(
    entry['reader'] as String,
    List<String>.from(entry['read'] as List),
  );

  Future<_LinuxBackendSelection?> _resolveBackend(String? desktop) async {
    final preferredBackend = LinuxProxyCommands.preferredBackend(desktop);
    if (preferredBackend != null) {
      return _resolveSelection(preferredBackend);
    }
    return null;
  }

  Future<_LinuxBackendSelection?> _resolveSelection(
    LinuxProxyBackend backend,
  ) async {
    switch (backend) {
      case LinuxProxyBackend.gnome:
      case LinuxProxyBackend.mate:
        if (await _executableChecker('gsettings')) {
          return _LinuxBackendSelection(backend, 'gsettings');
        }
        return null;
      case LinuxProxyBackend.kde:
        for (final executable in const ['kwriteconfig6', 'kwriteconfig5']) {
          if (await _executableChecker(executable) &&
              await _executableChecker(
                executable.replaceFirst('kwrite', 'kread'),
              )) {
            return _LinuxBackendSelection(backend, executable);
          }
        }
    }
    return null;
  }

  static Future<bool> _hasExecutable(String executable) async {
    try {
      final result = await Process.run('which', [executable]);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}

class LinuxProxyCommands {
  static LinuxProxyBackend? preferredBackend(String? desktop) {
    final desktops = _desktops(desktop);
    if (desktops.contains('KDE')) {
      return LinuxProxyBackend.kde;
    }
    if (desktops.contains('MATE')) {
      return LinuxProxyBackend.mate;
    }
    if (desktops.any(
      (desktop) =>
          const {'GNOME', 'CINNAMON', 'BUDGIE', 'UNITY'}.contains(desktop),
    )) {
      return LinuxProxyBackend.gnome;
    }
    return null;
  }

  static List<ProxyCommand> buildStart({
    required int port,
    required List<String> bypassDomain,
    required String? desktop,
    required String homeDir,
    Set<String>? availableExecutables,
  }) {
    final backend = _resolveBackend(
      desktop: desktop,
      availableExecutables: availableExecutables,
    );
    if (backend == null) {
      return [];
    }
    return buildStartForBackend(
      port: port,
      bypassDomain: bypassDomain,
      homeDir: homeDir,
      backend: backend,
      kdeConfigWriter: _resolveKdeConfigWriter(availableExecutables),
    );
  }

  static List<ProxyCommand> buildStop({
    required String? desktop,
    required String homeDir,
    Set<String>? availableExecutables,
  }) {
    final backend = _resolveBackend(
      desktop: desktop,
      availableExecutables: availableExecutables,
    );
    if (backend == null) {
      return [];
    }
    return buildStopForBackend(
      homeDir: homeDir,
      backend: backend,
      kdeConfigWriter: _resolveKdeConfigWriter(availableExecutables),
    );
  }

  static List<ProxyCommand> buildStartForBackend({
    required int port,
    required List<String> bypassDomain,
    required String homeDir,
    required LinuxProxyBackend backend,
    required String kdeConfigWriter,
  }) {
    return switch (backend) {
      LinuxProxyBackend.gnome => _buildGSettingsStart(
        port: port,
        bypassDomain: bypassDomain,
        schemaPrefix: 'org.gnome.system.proxy',
      ),
      LinuxProxyBackend.mate => _buildGSettingsStart(
        port: port,
        bypassDomain: bypassDomain,
        schemaPrefix: 'org.mate.system.proxy',
      ),
      LinuxProxyBackend.kde => _buildKdeStart(
        port: port,
        bypassDomain: bypassDomain,
        homeDir: homeDir,
        executable: kdeConfigWriter,
      ),
    };
  }

  static List<ProxyCommand> buildStopForBackend({
    required String homeDir,
    required LinuxProxyBackend backend,
    required String kdeConfigWriter,
  }) {
    return switch (backend) {
      LinuxProxyBackend.gnome => _buildGSettingsStop(
        schemaPrefix: 'org.gnome.system.proxy',
      ),
      LinuxProxyBackend.mate => _buildGSettingsStop(
        schemaPrefix: 'org.mate.system.proxy',
      ),
      LinuxProxyBackend.kde => _buildKdeStop(
        homeDir: homeDir,
        executable: kdeConfigWriter,
      ),
    };
  }

  static LinuxProxyBackend? _resolveBackend({
    required String? desktop,
    required Set<String>? availableExecutables,
  }) {
    final preferred = preferredBackend(desktop);
    if (preferred != null) {
      if (availableExecutables == null ||
          _isBackendAvailable(preferred, availableExecutables)) {
        return preferred;
      }
      return null;
    }
    return null;
  }

  static bool _isBackendAvailable(
    LinuxProxyBackend backend,
    Set<String> availableExecutables,
  ) {
    return switch (backend) {
      LinuxProxyBackend.gnome ||
      LinuxProxyBackend.mate => availableExecutables.contains('gsettings'),
      LinuxProxyBackend.kde =>
        availableExecutables.contains('kwriteconfig6') ||
            availableExecutables.contains('kwriteconfig5'),
    };
  }

  static String _resolveKdeConfigWriter(Set<String>? availableExecutables) {
    if (availableExecutables?.contains('kwriteconfig6') ?? false) {
      return 'kwriteconfig6';
    }
    return 'kwriteconfig5';
  }

  static List<ProxyCommand> _buildGSettingsStart({
    required int port,
    required List<String> bypassDomain,
    required String schemaPrefix,
  }) {
    final commands = <ProxyCommand>[
      ProxyCommand('gsettings', [
        'set',
        schemaPrefix,
        'ignore-hosts',
        _formatGSettingsStringList(bypassDomain),
      ]),
    ];
    for (final type in _ProxyType.values) {
      commands.addAll([
        ProxyCommand('gsettings', [
          'set',
          '$schemaPrefix.${type.name}',
          'host',
          proxyHost,
        ]),
        ProxyCommand('gsettings', [
          'set',
          '$schemaPrefix.${type.name}',
          'port',
          '$port',
        ]),
      ]);
    }
    commands.add(
      ProxyCommand('gsettings', ['set', schemaPrefix, 'mode', 'manual']),
    );
    return commands;
  }

  static List<ProxyCommand> _buildGSettingsStop({
    required String schemaPrefix,
  }) {
    return [
      ProxyCommand('gsettings', ['set', schemaPrefix, 'mode', 'none']),
    ];
  }

  static List<ProxyCommand> _buildKdeStart({
    required int port,
    required List<String> bypassDomain,
    required String homeDir,
    required String executable,
  }) {
    final configFile = path.join(homeDir, '.config', 'kioslaverc');
    return [
      ProxyCommand(executable, [
        '--file',
        configFile,
        '--group',
        'Proxy Settings',
        '--key',
        'NoProxyFor',
        bypassDomain.join(','),
      ]),
      for (final type in _ProxyType.values)
        ProxyCommand(executable, [
          '--file',
          configFile,
          '--group',
          'Proxy Settings',
          '--key',
          '${type.name}Proxy',
          '${type.name}://$proxyHost:$port',
        ]),
      ProxyCommand(executable, [
        '--file',
        configFile,
        '--group',
        'Proxy Settings',
        '--key',
        'ProxyType',
        '1',
      ]),
    ];
  }

  static List<ProxyCommand> _buildKdeStop({
    required String homeDir,
    required String executable,
  }) {
    return [
      ProxyCommand(executable, [
        '--file',
        path.join(homeDir, '.config', 'kioslaverc'),
        '--group',
        'Proxy Settings',
        '--key',
        'ProxyType',
        '0',
      ]),
    ];
  }

  static String _formatGSettingsStringList(List<String> values) {
    final escaped = values.map((value) {
      return value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    });
    return "[${escaped.map((value) => "'$value'").join(', ')}]";
  }

  static Set<String> _desktops(String? desktop) {
    if (desktop == null || desktop.isEmpty) {
      return {};
    }
    return desktop
        .split(':')
        .map((value) => value.trim().toUpperCase())
        .where((value) => value.isNotEmpty)
        .toSet();
  }
}

class _LinuxBackendSelection {
  final LinuxProxyBackend backend;
  final String executable;

  const _LinuxBackendSelection(this.backend, this.executable);
}
