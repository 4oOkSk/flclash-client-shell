import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'managed test entry enables the managed interface',
    () {
      expect(kPrivateClientMode, isTrue);
    },
    skip: Platform.environment['EXPECT_MANAGED_TESTS'] != '1',
  );
}
