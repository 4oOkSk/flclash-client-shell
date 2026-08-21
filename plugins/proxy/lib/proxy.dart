import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart';

import 'proxy_platform_interface.dart';

enum ProxyTypes { http, https, socks }

typedef ProxyProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  bool runInShell,
});

typedef ProxyExecutableChecker = Future<bool> Function(String executable);

@immutable
class ProxyCommand {
  final String executable;
  final List<String> args;
  final bool runInShell;

  const ProxyCommand(this.executable, this.args, {this.runInShell = false});
}

enum LinuxProxyBackend { gnome, mate, kde }

class Proxy extends ProxyPlatform {
  static String url = '127.0.0.1';

  final ProxyProcessRunner _processRunner;
  final ProxyExecutableChecker _executableChecker;

  Proxy({
    ProxyProcessRunner? processRunner,
    ProxyExecutableChecker? executableChecker,
  })  : _processRunner = processRunner ?? Process.run,
        _executableChecker = executableChecker ?? _hasExecutable;

  @override
  Future<bool?> startProxy(
    int port, [
    List<String> bypassDomain = const [],
  ]) async {
    return switch (Platform.operatingSystem) {
      'macos' => await _startProxyWithMacos(port, bypassDomain),
      'linux' => await _startProxyWithLinux(port, bypassDomain),
      'windows' => await ProxyPlatform.instance.startProxy(port, bypassDomain),
      String() => false,
    };
  }

  @override
  Future<bool?> stopProxy() async {
    return switch (Platform.operatingSystem) {
      'macos' => await _stopProxyWithMacos(),
      'linux' => await _stopProxyWithLinux(),
      'windows' => await ProxyPlatform.instance.stopProxy(),
      String() => false,
    };
  }

  Future<bool> _startProxyWithLinux(int port, List<String> bypassDomain) async {
    final homeDir = Platform.environment['HOME'];
    if (homeDir == null || homeDir.isEmpty) {
      return false;
    }
    final desktop = Platform.environment['XDG_CURRENT_DESKTOP'];
    final backend = await _resolveLinuxBackend(desktop);
    if (backend == null) {
      return false;
    }
    final kdeConfigWriter = await _resolveKdeConfigWriter();
    final commands = _buildLinuxStartCommands(
      port: port,
      bypassDomain: bypassDomain,
      desktop: desktop,
      homeDir: homeDir,
      backend: backend,
      kdeConfigWriter: kdeConfigWriter,
    );
    if (commands.isEmpty) {
      return false;
    }
    final applied = await _runCommands(commands);
    if (!applied) {
      await _runCommands(
        _buildLinuxStopCommands(
          desktop: desktop,
          homeDir: homeDir,
          backend: backend,
          kdeConfigWriter: kdeConfigWriter,
        ),
      );
    }
    return applied;
  }

  Future<bool> _stopProxyWithLinux() async {
    final homeDir = Platform.environment['HOME'];
    if (homeDir == null || homeDir.isEmpty) {
      return false;
    }
    final commands = await _resolveLinuxStopCommands(
      desktop: Platform.environment['XDG_CURRENT_DESKTOP'],
      homeDir: homeDir,
    );
    if (commands.isEmpty) {
      return false;
    }
    return _runCommands(commands);
  }

  Future<bool> _startProxyWithMacos(int port, List<String> bypassDomain) async {
    final devices = await _getNetworkDeviceListWithMacos();
    if (devices.isEmpty) {
      return false;
    }
    return _runCommands([
      _buildMacosElevatedCommand(
        devices,
        port: port,
        bypassDomain: bypassDomain,
        enable: true,
      ),
    ]);
  }

  Future<bool> _stopProxyWithMacos() async {
    final devices = await _getNetworkDeviceListWithMacos();
    return _stopProxyWithMacosDevices(devices);
  }

  Future<bool> _stopProxyWithMacosDevices(List<String> devices) async {
    if (devices.isEmpty) {
      return false;
    }
    final proxyEnabled = await _macosProxyIsEnabled(devices);
    if (proxyEnabled == false) {
      return true;
    }
    return _runCommands([
      _buildMacosElevatedCommand(
        devices,
        port: 0,
        bypassDomain: const [],
        enable: false,
      ),
    ]);
  }

  Future<List<String>> _getNetworkDeviceListWithMacos() async {
    final res = await _processRunner('/usr/sbin/networksetup', [
      '-listallnetworkservices',
    ]);
    if (res.exitCode != 0) {
      return [];
    }
    return _parseMacosNetworkServices(res.stdout.toString());
  }

  Future<bool?> _macosProxyIsEnabled(List<String> devices) async {
    const queryArguments = [
      '-getwebproxy',
      '-getsecurewebproxy',
      '-getsocksfirewallproxy',
      '-getautoproxyurl',
    ];
    try {
      for (final device in devices) {
        for (final argument in queryArguments) {
          final result = await _processRunner('/usr/sbin/networksetup', [
            argument,
            device,
          ]);
          if (result.exitCode != 0) {
            return null;
          }
          if (_parseMacosProxyEnabled(result.stdout.toString())) {
            return true;
          }
        }
      }
      return false;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _runCommands(Iterable<ProxyCommand> commands) async {
    try {
      for (final command in commands) {
        final result = await _processRunner(
          command.executable,
          command.args,
          runInShell: command.runInShell,
        );
        if (result.exitCode != 0) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<ProxyCommand>> _resolveLinuxStartCommands(
    int port,
    List<String> bypassDomain, {
    required String? desktop,
    required String homeDir,
  }) async {
    final backend = await _resolveLinuxBackend(desktop);
    if (backend == null) {
      return [];
    }
    return _buildLinuxStartCommands(
      port: port,
      bypassDomain: bypassDomain,
      desktop: desktop,
      homeDir: homeDir,
      backend: backend,
      kdeConfigWriter: await _resolveKdeConfigWriter(),
    );
  }

  Future<List<ProxyCommand>> _resolveLinuxStopCommands({
    required String? desktop,
    required String homeDir,
  }) async {
    final backend = await _resolveLinuxBackend(desktop);
    if (backend == null) {
      return [];
    }
    return _buildLinuxStopCommands(
      desktop: desktop,
      homeDir: homeDir,
      backend: backend,
      kdeConfigWriter: await _resolveKdeConfigWriter(),
    );
  }

  Future<LinuxProxyBackend?> _resolveLinuxBackend(String? desktop) async {
    final preferredBackend = _preferredLinuxBackend(desktop);
    if (preferredBackend != null &&
        await _isLinuxBackendAvailable(preferredBackend)) {
      return preferredBackend;
    }
    return null;
  }

  Future<bool> _isLinuxBackendAvailable(LinuxProxyBackend backend) async {
    return switch (backend) {
      LinuxProxyBackend.gnome => await _executableChecker('gsettings'),
      LinuxProxyBackend.mate => await _executableChecker('gsettings'),
      LinuxProxyBackend.kde => await _executableChecker('kwriteconfig6') ||
          await _executableChecker('kwriteconfig5'),
    };
  }

  Future<String> _resolveKdeConfigWriter() async {
    if (await _executableChecker('kwriteconfig6')) {
      return 'kwriteconfig6';
    }
    return 'kwriteconfig5';
  }

  static Future<bool> _hasExecutable(String executable) async {
    final result = await Process.run('which', [executable]);
    return result.exitCode == 0;
  }

  static LinuxProxyBackend? _preferredLinuxBackend(String? desktop) {
    final desktops = _linuxDesktops(desktop);
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

  static Set<String> _linuxDesktops(String? desktop) {
    if (desktop == null || desktop.isEmpty) {
      return {};
    }
    return desktop
        .split(':')
        .map((value) => value.trim().toUpperCase())
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  static List<ProxyCommand> _buildLinuxStartCommands({
    required int port,
    required List<String> bypassDomain,
    required String? desktop,
    required String homeDir,
    LinuxProxyBackend? backend,
    String kdeConfigWriter = 'kwriteconfig5',
    Set<String>? availableExecutables,
  }) {
    final resolvedBackend = backend ??
        _resolveLinuxBackendForBuild(
          desktop: desktop,
          availableExecutables: availableExecutables,
        );
    if (resolvedBackend == null) {
      return [];
    }
    return switch (resolvedBackend) {
      LinuxProxyBackend.gnome => _buildGSettingsStartCommands(
          port: port,
          bypassDomain: bypassDomain,
          schemaPrefix: 'org.gnome.system.proxy',
        ),
      LinuxProxyBackend.mate => _buildGSettingsStartCommands(
          port: port,
          bypassDomain: bypassDomain,
          schemaPrefix: 'org.mate.system.proxy',
        ),
      LinuxProxyBackend.kde => _buildKdeStartCommands(
          port: port,
          bypassDomain: bypassDomain,
          homeDir: homeDir,
          executable: _resolveKdeConfigWriterForBuild(
            availableExecutables,
            fallback: kdeConfigWriter,
          ),
        ),
    };
  }

  static List<ProxyCommand> _buildLinuxStopCommands({
    required String? desktop,
    required String homeDir,
    LinuxProxyBackend? backend,
    String kdeConfigWriter = 'kwriteconfig5',
    Set<String>? availableExecutables,
  }) {
    final resolvedBackend = backend ??
        _resolveLinuxBackendForBuild(
          desktop: desktop,
          availableExecutables: availableExecutables,
        );
    if (resolvedBackend == null) {
      return [];
    }
    return switch (resolvedBackend) {
      LinuxProxyBackend.gnome => _buildGSettingsStopCommands(
          schemaPrefix: 'org.gnome.system.proxy',
        ),
      LinuxProxyBackend.mate => _buildGSettingsStopCommands(
          schemaPrefix: 'org.mate.system.proxy',
        ),
      LinuxProxyBackend.kde => _buildKdeStopCommands(
          homeDir: homeDir,
          executable: _resolveKdeConfigWriterForBuild(
            availableExecutables,
            fallback: kdeConfigWriter,
          ),
        ),
    };
  }

  static LinuxProxyBackend? _resolveLinuxBackendForBuild({
    required String? desktop,
    required Set<String>? availableExecutables,
  }) {
    final preferredBackend = _preferredLinuxBackend(desktop);
    if (preferredBackend != null) {
      if (availableExecutables == null ||
          _isLinuxBackendAvailableForBuild(
            preferredBackend,
            availableExecutables,
          )) {
        return preferredBackend;
      }
      return null;
    }
    return null;
  }

  static bool _isLinuxBackendAvailableForBuild(
    LinuxProxyBackend backend,
    Set<String> availableExecutables,
  ) {
    return switch (backend) {
      LinuxProxyBackend.gnome => availableExecutables.contains('gsettings'),
      LinuxProxyBackend.mate => availableExecutables.contains('gsettings'),
      LinuxProxyBackend.kde => availableExecutables.contains('kwriteconfig6') ||
          availableExecutables.contains('kwriteconfig5'),
    };
  }

  static String _resolveKdeConfigWriterForBuild(
    Set<String>? availableExecutables, {
    required String fallback,
  }) {
    if (availableExecutables?.contains('kwriteconfig6') ?? false) {
      return 'kwriteconfig6';
    }
    if (availableExecutables?.contains('kwriteconfig5') ?? false) {
      return 'kwriteconfig5';
    }
    return fallback;
  }

  static List<ProxyCommand> _buildGSettingsStartCommands({
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
    for (final type in ProxyTypes.values) {
      commands.addAll([
        ProxyCommand('gsettings', [
          'set',
          '$schemaPrefix.${type.name}',
          'host',
          url,
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

  static List<ProxyCommand> _buildGSettingsStopCommands({
    required String schemaPrefix,
  }) {
    return [
      ProxyCommand('gsettings', ['set', schemaPrefix, 'mode', 'none']),
    ];
  }

  static List<ProxyCommand> _buildKdeStartCommands({
    required int port,
    required List<String> bypassDomain,
    required String homeDir,
    required String executable,
  }) {
    final configDir = join(homeDir, '.config');
    final commands = <ProxyCommand>[];
    commands.addAll([
      ProxyCommand(executable, [
        '--file',
        join(configDir, 'kioslaverc'),
        '--group',
        'Proxy Settings',
        '--key',
        'NoProxyFor',
        bypassDomain.join(','),
      ]),
    ]);
    for (final type in ProxyTypes.values) {
      commands.add(
        ProxyCommand(executable, [
          '--file',
          join(configDir, 'kioslaverc'),
          '--group',
          'Proxy Settings',
          '--key',
          '${type.name}Proxy',
          '${type.name}://$url:$port',
        ]),
      );
    }
    commands.add(
      ProxyCommand(executable, [
        '--file',
        join(configDir, 'kioslaverc'),
        '--group',
        'Proxy Settings',
        '--key',
        'ProxyType',
        '1',
      ]),
    );
    return commands;
  }

  static List<ProxyCommand> _buildKdeStopCommands({
    required String homeDir,
    required String executable,
  }) {
    return [
      ProxyCommand(executable, [
        '--file',
        join(homeDir, '.config', 'kioslaverc'),
        '--group',
        'Proxy Settings',
        '--key',
        'ProxyType',
        '0',
      ]),
    ];
  }

  static String _formatGSettingsStringList(List<String> values) {
    if (values.isEmpty) {
      return '[]';
    }
    final escaped = values.map((value) => "'${value.replaceAll("'", "\\'")}'");
    return '[${escaped.join(', ')}]';
  }

  static List<ProxyCommand> _buildMacosStartCommands(
    String dev,
    int port,
    List<String> bypassDomain,
  ) {
    return [
      ProxyCommand('/usr/sbin/networksetup', [
        '-setautoproxystate',
        dev,
        'off',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setwebproxy',
        dev,
        url,
        '$port',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsecurewebproxy',
        dev,
        url,
        '$port',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsocksfirewallproxy',
        dev,
        url,
        '$port',
      ]),
      _buildMacosProxyBypassCommand(dev, bypassDomain),
      ProxyCommand('/usr/sbin/networksetup', ['-setwebproxystate', dev, 'on']),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsecurewebproxystate',
        dev,
        'on',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsocksfirewallproxystate',
        dev,
        'on',
      ]),
    ];
  }

  static List<ProxyCommand> _buildMacosStopCommands(String dev) {
    return [
      ProxyCommand('/usr/sbin/networksetup', [
        '-setautoproxystate',
        dev,
        'off',
      ]),
      ProxyCommand('/usr/sbin/networksetup', ['-setwebproxystate', dev, 'off']),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsecurewebproxystate',
        dev,
        'off',
      ]),
      ProxyCommand('/usr/sbin/networksetup', [
        '-setsocksfirewallproxystate',
        dev,
        'off',
      ]),
      _buildMacosProxyBypassCommand(dev, const []),
    ];
  }

  static ProxyCommand _buildMacosProxyBypassCommand(
    String dev,
    List<String> bypassDomain,
  ) {
    return ProxyCommand('/usr/sbin/networksetup', [
      '-setproxybypassdomains',
      dev,
      if (bypassDomain.isEmpty) 'Empty' else ...bypassDomain,
    ]);
  }

  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\\''")}'";
  }

  static String _macosShellCommand(ProxyCommand command) {
    return <String>[
      _shellQuote(command.executable),
      ...command.args.map(_shellQuote),
    ].join(' ');
  }

  static String _escapeAppleScriptString(String value) {
    return value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  }

  static String _buildMacosShell(
    List<String> devices, {
    required int port,
    required List<String> bypassDomain,
    required bool enable,
  }) {
    final stopCommands = devices
        .expand(_buildMacosStopCommands)
        .map(_macosShellCommand)
        .toList();
    late final String shell;
    if (enable) {
      final startCommands = devices
          .expand(
            (device) => _buildMacosStartCommands(device, port, bypassDomain),
          )
          .map(_macosShellCommand)
          .toList();
      final rollback =
          stopCommands.map((command) => '$command || true').join('; ');
      shell = <String>[
        'set -e',
        'cleanup() { code=\$?; trap - EXIT; if [ "\$code" -ne 0 ]; then $rollback; fi; exit "\$code"; }',
        'trap cleanup EXIT',
        ...startCommands,
        'trap - EXIT',
      ].join('; ');
    } else {
      shell = <String>[
        'status=0',
        ...stopCommands.map((command) => '$command || status=1'),
        'exit "\$status"',
      ].join('; ');
    }
    return shell;
  }

  static ProxyCommand _buildMacosElevatedCommand(
    List<String> devices, {
    required int port,
    required List<String> bypassDomain,
    required bool enable,
  }) {
    final shell = _buildMacosShell(
      devices,
      port: port,
      bypassDomain: bypassDomain,
      enable: enable,
    );
    return ProxyCommand('/usr/bin/osascript', [
      '-e',
      'do shell script "${_escapeAppleScriptString(shell)}" with administrator privileges',
    ]);
  }

  static List<String> _parseMacosNetworkServices(String stdout) {
    return stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .where((line) => !line.startsWith('*'))
        .where((line) => !line.startsWith('An asterisk '))
        .toList();
  }

  static bool _parseMacosProxyEnabled(String stdout) {
    return stdout.split('\n').any(
          (line) => line.trim().toLowerCase() == 'enabled: yes',
        );
  }

  @visibleForTesting
  static List<ProxyCommand> buildLinuxStartCommandsForTest({
    required int port,
    required List<String> bypassDomain,
    required String? desktop,
    required String homeDir,
    Set<String>? availableExecutables,
  }) {
    return _buildLinuxStartCommands(
      port: port,
      bypassDomain: bypassDomain,
      desktop: desktop,
      homeDir: homeDir,
      availableExecutables: availableExecutables,
    );
  }

  @visibleForTesting
  static List<String> parseMacosNetworkServicesForTest(String stdout) {
    return _parseMacosNetworkServices(stdout);
  }

  @visibleForTesting
  static ProxyCommand buildMacosProxyBypassCommandForTest(
    String dev,
    List<String> bypassDomain,
  ) {
    return _buildMacosProxyBypassCommand(dev, bypassDomain);
  }

  @visibleForTesting
  static ProxyCommand buildMacosElevatedCommandForTest(
    List<String> devices, {
    required int port,
    required List<String> bypassDomain,
    required bool enable,
  }) {
    return _buildMacosElevatedCommand(
      devices,
      port: port,
      bypassDomain: bypassDomain,
      enable: enable,
    );
  }

  @visibleForTesting
  static String buildMacosShellForTest(
    List<String> devices, {
    required int port,
    required List<String> bypassDomain,
    required bool enable,
  }) {
    return _buildMacosShell(
      devices,
      port: port,
      bypassDomain: bypassDomain,
      enable: enable,
    );
  }

  @visibleForTesting
  static bool parseMacosProxyEnabledForTest(String stdout) {
    return _parseMacosProxyEnabled(stdout);
  }

  @visibleForTesting
  Future<bool> stopProxyWithMacosDevicesForTest(List<String> devices) {
    return _stopProxyWithMacosDevices(devices);
  }
}
