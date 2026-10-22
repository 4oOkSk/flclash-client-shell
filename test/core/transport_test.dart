import 'package:fl_clash/common/constant.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows Core pipe uses a 128-bit random suffix', () {
    const pipeNamespace = r'\\.\pipe\';
    const suffixLength = 32;
    expect(windowsPipeName, startsWith(pipeNamespace));
    expect(
      windowsPipeName.substring(
        pipeNamespace.length,
        windowsPipeName.length - suffixLength,
      ),
      matches(RegExp(r'^[A-Za-z][A-Za-z0-9]*Core_$')),
    );
    expect(
      windowsPipeName.substring(windowsPipeName.length - suffixLength),
      matches(RegExp(r'^[0-9a-f]{32}$')),
    );
  });
}
