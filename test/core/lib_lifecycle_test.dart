import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/lib.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final core = CoreLib();

  tearDown(() async => core.stop());
  tearDownAll(() async => core.close());

  test('restart cannot issue a new start after a newer stop', () async {
    await core.start();
    final restart = core.restart();
    final stop = core.stop();
    expect((await restart).outcome, CoreLifecycleOutcome.superseded);
    await stop;
    expect((await core.stop()).outcome, CoreLifecycleOutcome.coalesced);
  });

  test(
    'restart is one revision and concurrent restart/start coalesce',
    () async {
      await core.start();
      final restart = core.restart();
      expect(core.restart(), same(restart));
      expect(core.start(), same(restart));
      final result = await restart;
      expect(result.outcome, CoreLifecycleOutcome.applied);
      final stop = await core.stop();
      expect(stop.revision, result.revision + 1);
      expect(stop.outcome, CoreLifecycleOutcome.applied);
    },
  );
}
