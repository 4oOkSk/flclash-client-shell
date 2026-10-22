import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fl_clash/common/backup_restore.dart';
import 'package:fl_clash/common/file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  setUp(
    () async => temp = await Directory.systemTemp.createTemp('restore-test-'),
  );
  tearDown(() async => temp.delete(recursive: true));

  test('valid directory entries and attachments extract', () async {
    final archive = Archive()
      ..add(ArchiveFile.directory('profiles/'))
      ..add(ArchiveFile.string('profiles/1.yaml', 'rules: []'));
    final root = Directory(p.join(temp.path, 'stage'));
    await extractBackupArchive(archive, root);
    expect(
      await File(p.join(root.path, 'profiles/1.yaml')).readAsString(),
      'rules: []',
    );
  });

  for (final name in [
    '../sentinel',
    '/absolute',
    r'C:\absolute',
    r'..\sentinel',
  ]) {
    test('rejects $name before any write', () async {
      final sentinel = File(p.join(temp.path, 'sentinel'));
      await sentinel.writeAsString('before');
      final root = Directory(p.join(temp.path, 'stage'));
      final archive = Archive()
        ..add(ArchiveFile.string('good.txt', 'good'))
        ..add(ArchiveFile.string(name, 'bad'));
      await expectLater(
        extractBackupArchive(archive, root),
        throwsFormatException,
      );
      expect(await root.exists(), false);
      expect(await sentinel.readAsString(), 'before');
    });
  }

  test('missing copy source fails without creating either file', () async {
    final source = File(p.join(temp.path, 'absent'));
    final target = p.join(temp.path, 'target');
    await expectLater(
      source.safeCopy(target),
      throwsA(isA<FileSystemException>()),
    );
    expect(await source.exists(), false);
    expect(await File(target).exists(), false);
  });

  test('declared size is enforced during extraction', () async {
    final root = Directory(p.join(temp.path, 'stage'));
    final entry = ArchiveFile('large', 1, [1, 2, 3]);
    entry.size = 1;
    await expectLater(
      extractBackupArchive(Archive()..add(entry), root),
      throwsFormatException,
    );
    expect(
      await File(p.join(root.path, 'large')).length(),
      lessThanOrEqualTo(1),
    );
  });

  test('existing staging directory is never reused', () async {
    final archive = Archive()..add(ArchiveFile.string('one', 'new'));
    await expectLater(
      extractBackupArchive(archive, temp),
      throwsFormatException,
    );
    expect(await File(p.join(temp.path, 'one')).exists(), false);
  });

  test('file transaction restores replaced and new attachments', () async {
    final home = await Directory(p.join(temp.path, 'home')).create();
    final old = File(p.join(home.path, 'profiles/1.yaml'));
    await old.parent.create();
    await old.writeAsString('old');
    final incoming = File(p.join(temp.path, 'incoming'));
    await incoming.writeAsString('new');
    final added = p.join(home.path, 'scripts/2.js');
    final incomingScript = File(p.join(temp.path, 'incoming-script'));
    await incomingScript.writeAsString('script');
    final transaction = RestoreFileTransaction(
      home: home,
      files: {incoming.path: old.path, incomingScript.path: added},
    );
    await transaction.replace();
    expect(await old.readAsString(), 'new');
    await transaction.rollback();
    expect(await old.readAsString(), 'old');
    expect(await File(added).exists(), false);
  });

  test('unsafe targets are rejected before changing valid files', () async {
    final home = await Directory(p.join(temp.path, 'home')).create();
    final old = File(p.join(home.path, 'one'));
    await old.writeAsString('old');
    final incoming = File(p.join(temp.path, 'incoming'));
    await incoming.writeAsString('new');
    final second = File(p.join(temp.path, 'second'));
    await second.writeAsString('second');
    final transaction = RestoreFileTransaction(
      home: home,
      files: {
        incoming.path: old.path,
        second.path: p.join(temp.path, 'outside'),
      },
    );
    await expectLater(
      transaction.replace(),
      throwsA(isA<FileSystemException>()),
    );
    expect(await old.readAsString(), 'old');
  });
}
