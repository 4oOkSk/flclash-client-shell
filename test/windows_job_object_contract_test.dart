import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows runner fails closed when Job Object setup fails', () {
    final source = File('windows/runner/main.cpp').readAsStringSync();

    expect(source, contains('JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE'));
    expect(source, contains('if (process_lifetime_job == nullptr) {'));
    expect(
      RegExp(
        r'if \(process_lifetime_job == nullptr\) \{\s*'
        r'::CloseHandle\(single_instance\);\s*'
        r'return EXIT_FAILURE;\s*\}',
      ).hasMatch(source),
      isTrue,
    );
  });

  test('Windows runner has one linker-owned UAC execution level', () {
    final cmake = File('windows/runner/CMakeLists.txt').readAsStringSync();
    final manifest = File(
      'windows/runner/runner.exe.manifest',
    ).readAsStringSync();

    expect(
      cmake,
      contains(
        "/MANIFESTUAC:level='requireAdministrator' uiAccess='false'",
      ),
    );
    expect(manifest, isNot(contains('<requestedExecutionLevel')));
    expect(manifest, isNot(contains('<trustInfo')));
  });
}
