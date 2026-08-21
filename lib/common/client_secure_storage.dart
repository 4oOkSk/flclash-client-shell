import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'constant.dart';
import 'path.dart';

class ClientSecureKey {
  const ClientSecureKey({required this.encoded, required this.source});

  final String encoded;
  final String source;
}

class ClientSecureStorage {
  static const _androidChannel = MethodChannel('$packageName/app');
  static const _macosChannel = MethodChannel(
    '$packageName/client_secure_storage',
  );
  static const _keyName = 'client-cache-master-key-v1';
  static const _macosFallbackKeyName = '.client-system-key.macos';
  static const _linuxAttributes = <String>[
    'service',
    'HarborProxy',
    'key',
    _keyName,
  ];

  Future<ClientSecureKey?> loadOrCreate() async {
    if (!kPrivateClientMode) return null;
    try {
      final existing = await _read();
      if (_valid(existing)) {
        return ClientSecureKey(
          encoded: existing!,
          source: _activeSource ?? _platformSource,
        );
      }
      final generated = base64Encode(
        List<int>.generate(32, (_) => Random.secure().nextInt(256)),
      );
      if (!await _write(generated)) return null;
      final verified = await _read();
      if (verified != generated) return null;
      return ClientSecureKey(
        encoded: generated,
        source: _activeSource ?? _platformSource,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> delete() async {
    if (!kPrivateClientMode) return;
    try {
      if (Platform.isAndroid) {
        await _androidChannel.invokeMethod<void>('clientSecureStorageDelete');
      } else if (Platform.isMacOS) {
        try {
          await _macosChannel.invokeMethod<void>('delete');
        } catch (_) {
          // The unsigned fallback remains independently removable even when
          // the native Data Protection Keychain bridge is unavailable.
        }
        await _deleteMacOSFallback();
      } else if (Platform.isWindows) {
        final file = File(await _windowsFilePath());
        if (await file.exists()) await file.delete();
      } else if (Platform.isLinux) {
        final tool = _linuxSecretTool();
        if (tool != null) {
          await _runProcess(tool, ['clear', ..._linuxAttributes]);
        }
      }
    } catch (_) {
      // Logout must still complete when a platform key store is unavailable.
    }
  }

  String? _activeSource;

  String get _platformSource {
    if (Platform.isAndroid) return 'android-keystore';
    if (Platform.isWindows) return 'windows-dpapi';
    if (Platform.isMacOS) return 'macos-data-protection-keychain';
    return 'linux-secret-service';
  }

  bool _valid(String? value) {
    if (value == null) return false;
    try {
      return base64Decode(value).length == 32;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _read() async {
    if (Platform.isAndroid) {
      return _androidChannel.invokeMethod<String>('clientSecureStorageRead');
    }
    if (Platform.isMacOS) {
      final value = await _macosChannel.invokeMethod<String>('read');
      if (_valid(value)) {
        _activeSource = 'macos-data-protection-keychain';
        return value;
      }
      return _readMacOSFallback();
    }
    if (Platform.isWindows) return _readWindows();
    if (Platform.isLinux) return _readLinux();
    return null;
  }

  Future<bool> _write(String value) async {
    if (Platform.isAndroid) {
      return await _androidChannel.invokeMethod<bool>(
            'clientSecureStorageWrite',
            {'value': value},
          ) ??
          false;
    }
    if (Platform.isMacOS) {
      final stored =
          await _macosChannel.invokeMethod<bool>('write', {'value': value}) ??
          false;
      if (stored) {
        _activeSource = 'macos-data-protection-keychain';
        return true;
      }
      return _writeMacOSFallback(value);
    }
    if (Platform.isWindows) return _writeWindows(value);
    if (Platform.isLinux) return _writeLinux(value);
    return false;
  }

  Future<String> _windowsFilePath() async {
    return p.join(await appPath.homeDirPath, '.client-system-key.dpapi');
  }

  Future<String> _macosFallbackFilePath() async {
    return p.join(await appPath.homeDirPath, _macosFallbackKeyName);
  }

  Future<String?> _readMacOSFallback() async {
    final path = await _macosFallbackFilePath();
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final file = File(path);
    final stat = await file.stat();
    if (stat.mode & 0x1ff != 0x180) return null;
    final value = (await file.readAsString()).trim();
    if (!_valid(value)) return null;
    _activeSource = 'macos-file-fallback';
    return value;
  }

  Future<bool> _writeMacOSFallback(String value) async {
    if (!_valid(value)) return false;
    final path = await _macosFallbackFilePath();
    final file = File(path);
    final temporary = File('$path.tmp');
    try {
      await file.parent.create(recursive: true);
      if (await temporary.exists()) await temporary.delete();
      await temporary.writeAsString(value, flush: true);
      final chmod = await Process.run('/bin/chmod', ['600', temporary.path]);
      if (chmod.exitCode != 0) return false;
      if (await file.exists()) await file.delete();
      await temporary.rename(path);
      final stat = await file.stat();
      if (stat.mode & 0x1ff != 0x180) return false;
      _activeSource = 'macos-file-fallback';
      return true;
    } catch (_) {
      return false;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _deleteMacOSFallback() async {
    final path = await _macosFallbackFilePath();
    for (final file in [File(path), File('$path.tmp')]) {
      if (await file.exists()) await file.delete();
    }
    _activeSource = null;
  }

  Future<String?> _readWindows() async {
    final file = File(await _windowsFilePath());
    if (!await file.exists()) return null;
    final protected = (await file.readAsString()).trim();
    if (protected.isEmpty) return null;
    final result = await _runPowerShell(
      r"$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Security;$p=[Console]::In.ReadToEnd().Trim();$b=[Convert]::FromBase64String($p);$d=[Security.Cryptography.ProtectedData]::Unprotect($b,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser);[Console]::Out.Write([Convert]::ToBase64String($d))",
      input: protected,
    );
    return result?.stdout.trim();
  }

  Future<bool> _writeWindows(String value) async {
    final result = await _runPowerShell(
      r"$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Security;$p=[Console]::In.ReadToEnd().Trim();$b=[Convert]::FromBase64String($p);$d=[Security.Cryptography.ProtectedData]::Protect($b,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser);[Console]::Out.Write([Convert]::ToBase64String($d))",
      input: value,
    );
    final protected = result?.stdout.trim() ?? '';
    if (protected.isEmpty) return false;
    final file = File(await _windowsFilePath());
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(protected, flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
    return true;
  }

  Future<_ProcessResult?> _runPowerShell(
    String script, {
    required String input,
  }) async {
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final executable = p.join(
      systemRoot,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    final encoded = base64Encode(_utf16le(script));
    return _runProcess(executable, [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-EncodedCommand',
      encoded,
    ], input: input);
  }

  List<int> _utf16le(String value) {
    final bytes = <int>[];
    for (final unit in value.codeUnits) {
      bytes
        ..add(unit & 0xff)
        ..add((unit >> 8) & 0xff);
    }
    return bytes;
  }

  String? _linuxSecretTool() {
    for (final candidate in const [
      '/usr/bin/secret-tool',
      '/bin/secret-tool',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  Future<String?> _readLinux() async {
    final tool = _linuxSecretTool();
    if (tool == null) return null;
    final result = await _runProcess(tool, ['lookup', ..._linuxAttributes]);
    if (result == null || result.exitCode != 0) return null;
    return result.stdout.trim();
  }

  Future<bool> _writeLinux(String value) async {
    final tool = _linuxSecretTool();
    if (tool == null) return false;
    final result = await _runProcess(tool, [
      'store',
      '--label=HarborProxy client cache key',
      ..._linuxAttributes,
    ], input: value);
    return result?.exitCode == 0;
  }

  Future<_ProcessResult?> _runProcess(
    String executable,
    List<String> arguments, {
    String? input,
  }) async {
    Process? process;
    try {
      process = await Process.start(executable, arguments);
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.drain<void>();
      if (input != null) process.stdin.write(input);
      await process.stdin.close();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          process?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      final output = await stdout;
      await stderr;
      return _ProcessResult(exitCode, output);
    } catch (_) {
      process?.kill(ProcessSignal.sigkill);
      return null;
    }
  }
}

class _ProcessResult {
  const _ProcessResult(this.exitCode, this.stdout);

  final int exitCode;
  final String stdout;
}

final clientSecureStorage = ClientSecureStorage();
