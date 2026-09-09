import 'dart:async';

import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test(
    'recovery persistence failure is separate from successful core application',
    () async {
      final store = Preferences();
      await store.sharedPreferencesCompleter.future;
      const overlay = PrivateRouteOverlay(rules: ['DOMAIN,example.com,REJECT']);
      expect(await store.saveAppliedPrivateRoute(overlay), isTrue);
      expect((await store.getAppliedPrivateRoute())?.rules, overlay.rules);
      final original = store.sharedPreferencesCompleter;
      addTearDown(() => store.sharedPreferencesCompleter = original);
      store.sharedPreferencesCompleter = Completer<SharedPreferences?>();
      final saving = store.saveAppliedPrivateRoute(overlay);
      store.sharedPreferencesCompleter.completeError(
        StateError('storage unavailable'),
      );
      expect(await saving, isFalse);
    },
  );
}
