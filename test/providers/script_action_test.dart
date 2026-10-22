import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/database/database.dart';
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

class _FailingWrite extends ScriptAction {
  @override
  Future<void> writeRecord(Script script) async {
    await super.writeRecord(script);
    throw StateError('synthetic database failure');
  }

  @override
  Future<void> removeRecord(int id) async {
    await super.removeRecord(id);
    throw StateError('synthetic deletion failure');
  }
}

class _FailingRollback extends ScriptAction {
  @override
  Future<void> writeRecord(Script script) async {
    final file = File(await script.path);
    await file.delete();
    await Directory(file.path).create();
    await File('${file.path}/blocking').writeAsString('synthetic');
    throw StateError('synthetic rollback failure');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform previous;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('script-transactions-');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
  });
  tearDownAll(() async {
    await database.close();
    PathProviderPlatform.instance = previous;
    await root.delete(recursive: true);
  });
  setUp(() async => database.delete(database.scripts).go());

  Future<Script> seed(int id, String name, String body) async {
    final script = Script(
      id: id,
      label: name,
      lastUpdateTime: DateTime.utc(2026, 1),
    );
    await database.scripts.put(script.toCompanion());
    final file = File(await script.path);
    await file.parent.create(recursive: true);
    await file.writeAsString(body);
    return script;
  }

  Future<void> expectNoTemporaryFiles() async {
    final home = Directory(await appPath.homeDirPath);
    final paths = await home.list().map((entry) => entry.path).toList();
    expect(
      paths.where(
        (path) =>
            path.contains('.script-save-') ||
            path.contains('.restore-rollback-'),
      ),
      isEmpty,
    );
  }

  test('save and rename commit content and database together', () async {
    final script = await seed(1, 'old', 'before');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final saved = await container
        .read(scriptActionProvider.notifier)
        .save(script.copyWith(label: ' new name '), 'after');
    expect(saved.label, ' new name ');
    expect(await File(await script.path).readAsString(), 'after');
    expect((await database.scriptsDao.get(1).getSingle()).label, ' new name ');
    await expectNoTemporaryFiles();
  });

  test('duplicate name is rejected before touching original bytes', () async {
    final script = await seed(2, 'first', 'original');
    await seed(3, 'taken', 'other');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await expectLater(
      container
          .read(scriptActionProvider.notifier)
          .save(script.copyWith(label: 'taken'), 'must not be written'),
      throwsA(isA<ScriptNameConflict>()),
    );
    expect(await File(await script.path).readAsString(), 'original');
    expect((await database.scriptsDao.get(2).getSingle()).label, 'first');
    await expectNoTemporaryFiles();
  });

  test('database failure rolls both original content and name back', () async {
    final script = await seed(4, 'first', 'original');
    final container = ProviderContainer(
      overrides: [scriptActionProvider.overrideWith(_FailingWrite.new)],
    );
    addTearDown(container.dispose);
    await expectLater(
      container
          .read(scriptActionProvider.notifier)
          .save(script.copyWith(label: 'renamed'), 'must roll back'),
      throwsStateError,
    );
    expect(await File(await script.path).readAsString(), 'original');
    expect((await database.scriptsDao.get(4).getSingle()).label, 'first');
    await expectNoTemporaryFiles();
  });

  test(
    'simultaneous same-name saves serialize and reject the second',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final action = container.read(scriptActionProvider.notifier);
      final outcomes = await Future.wait([
        for (final id in [5, 6])
          action
              .save(
                Script(id: id, label: 'same', lastUpdateTime: DateTime.now()),
                'body $id',
              )
              .then<Object>((value) => value, onError: (Object error) => error),
      ]);
      expect(outcomes.whereType<Script>(), hasLength(1));
      expect(outcomes.whereType<ScriptNameConflict>(), hasLength(1));
      expect(await database.scriptsDao.query().get(), hasLength(1));
      await expectNoTemporaryFiles();
    },
  );

  test('delete waits for the database and removes its original file', () async {
    final script = await seed(8, 'remove me', 'original');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(scriptActionProvider.notifier).remove(script);
    expect(await database.scriptsDao.get(8).getSingleOrNull(), isNull);
    expect(await File(await script.path).exists(), isFalse);
  });

  test('failed database deletion cannot erase the original file', () async {
    final script = await seed(9, 'keep me', 'original');
    final container = ProviderContainer(
      overrides: [scriptActionProvider.overrideWith(_FailingWrite.new)],
    );
    addTearDown(container.dispose);
    await expectLater(
      container.read(scriptActionProvider.notifier).remove(script),
      throwsStateError,
    );
    expect(await File(await script.path).readAsString(), 'original');
    expect((await database.scriptsDao.get(9).getSingle()).label, 'keep me');
  });

  test('failed rollback preserves a readable recovery copy', () async {
    final script = await seed(7, 'first', 'recoverable original');
    final container = ProviderContainer(
      overrides: [scriptActionProvider.overrideWith(_FailingRollback.new)],
    );
    addTearDown(container.dispose);
    await expectLater(
      container.read(scriptActionProvider.notifier).save(script, 'replacement'),
      throwsA(isA<FileSystemException>()),
    );
    final recovery = await Directory(await appPath.homeDirPath)
        .list()
        .where((entry) => entry.path.contains('.restore-rollback-'))
        .toList();
    expect(recovery, hasLength(1));
    final files = await (recovery.single as Directory)
        .list(recursive: true)
        .where((entry) => entry is File)
        .cast<File>()
        .toList();
    expect(
      await Future.wait(files.map((file) => file.readAsString())),
      contains('recoverable original'),
    );
    expect((await database.scriptsDao.get(7).getSingle()).label, 'first');
  });
}
