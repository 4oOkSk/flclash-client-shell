part of '../action.dart';

class ScriptNameConflict implements Exception {}

@Riverpod(keepAlive: true)
class ScriptAction extends _$ScriptAction {
  final _mutationQueue = SerialTaskScheduler();

  @override
  void build() {}

  @protected
  Future<void> writeRecord(Script script) =>
      database.scripts.put(script.toCompanion());

  @protected
  Future<void> removeRecord(int id) async {
    await database.scripts.remove((table) => table.id.equals(id));
  }

  Future<void> remove(Script script) => _mutationQueue.run(() async {
    // The original file stays intact if the database deletion fails.
    await database.transaction(() => removeRecord(script.id));
    try {
      await File(await script.path).safeDelete();
    } on FileSystemException {
      // The now-unreferenced attachment is also swept by store cleanup.
      commonPrint.log(
        'Deleted script attachment cleanup unavailable',
        logLevel: LogLevel.warning,
      );
    }
    if (ref.mounted) ref.invalidate(scriptsProvider);
  });

  Future<Script> save(Script script, String content) =>
      _mutationQueue.run(() async {
        if (script.label.trim().isEmpty) {
          throw const FormatException('Empty script name');
        }
        final home = Directory(await appPath.homeDirPath);
        if (await FileSystemEntity.type(home.path, followLinks: false) ==
            FileSystemEntityType.link) {
          throw const FileSystemException('Script home is a link');
        }
        await home.create(recursive: true);
        final stage = await home.createTemp('.script-save-');
        final staged = File('${stage.path}/${script.fileName}');
        final files = RestoreFileTransaction(
          home: home,
          files: {staged.path: await script.path},
        );
        final saved = script.copyWith(lastUpdateTime: DateTime.now());
        var rollbackFailed = false;
        try {
          await database.transaction(() async {
            final existing = await database.scriptsDao.query().get();
            if (existing.any(
              (item) => item.id != saved.id && item.label == saved.label,
            )) {
              throw ScriptNameConflict();
            }
            await staged.writeAsString(content, flush: true);
            await files.replace();
            await writeRecord(saved);
          });
        } catch (error, stack) {
          try {
            await files.rollback();
          } catch (_) {
            rollbackFailed = true;
            rethrow;
          }
          Error.throwWithStackTrace(error, stack);
        } finally {
          if (!rollbackFailed) {
            await files.cleanup();
            try {
              await stage.delete(recursive: true);
            } on FileSystemException {
              commonPrint.log(
                'Script temporary cleanup unavailable',
                logLevel: LogLevel.warning,
              );
            }
          }
        }
        if (ref.mounted) ref.invalidate(scriptsProvider);
        return saved;
      });
}
