import 'dart:io';

import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:riverpod/riverpod.dart';

class _Paths extends PathProviderPlatform {
  final String root;
  _Paths(this.root);
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform previous;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('generic-script-');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
  });
  tearDownAll(() async {
    await database.close();
    PathProviderPlatform.instance = previous;
    await directory.delete(recursive: true);
  });

  test(
    'selected missing script record blocks generic setup snapshot',
    () async {
      final profile = Profile.normal(
        label: 'Test',
      ).copyWith(id: 7, scriptId: 41, overwriteType: OverwriteType.script);
      final container = ProviderContainer(
        overrides: [profileProvider(7).overrideWith((_) => profile)],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(setupStateProvider(7).future),
        throwsFormatException,
      );
    },
  );

  for (final content in <String?>[null, '', '   ']) {
    test(
      'selected script with missing/empty file blocks config generation ($content)',
      () async {
        final script = Script(
          id: 42,
          label: 'Test',
          lastUpdateTime: DateTime.now(),
        );
        final file = File(await script.path);
        if (content != null) {
          await file.parent.create(recursive: true);
          await file.writeAsString(content);
        }
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final state = SetupState(
          profileId: 7,
          profileLastUpdateDate: null,
          overwriteType: OverwriteType.script,
          rules: [],
          proxyGroups: [],
          addedRules: [],
          script: script,
          overrideDns: false,
          dns: defaultDns,
        );
        await expectLater(
          container
              .read(setupActionProvider.notifier)
              .getProfile(
                setupState: state,
                patchConfig: container.read(patchClashConfigProvider),
              ),
          throwsFormatException,
        );
        if (await file.exists()) await file.delete();
      },
    );
  }
}
