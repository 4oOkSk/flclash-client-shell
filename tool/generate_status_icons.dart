import 'dart:io';

/// Compatibility entry point for the old tray-icon generator.
///
/// Branding now has one authoritative source and generator. Keeping this
/// wrapper prevents an old maintenance command from restoring the inherited
/// legacy tray glyphs.
Future<void> main() async {
  final result = await Process.start(
    'python3',
    ['tool/generate_branding_assets.py'],
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await result.exitCode;
}
