import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Validate the complete archive before opening any output file.
Future<void> extractBackupArchive(Archive archive, Directory root) async {
  if (await FileSystemEntity.type(root.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw const FormatException(
      'Backup extraction requires a fresh staging directory',
    );
  }
  final entries = <String, ArchiveFile>{};
  var totalSize = 0;
  for (final entry in archive.files) {
    final name = entry.name.replaceAll('\\', '/');
    if (entry.isSymbolicLink ||
        name.contains('\u0000') ||
        name.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:').hasMatch(name) ||
        name.split('/').contains('..')) {
      throw const FormatException('Unsafe backup path');
    }
    final relative = p.posix.normalize(name);
    if (relative == '.' || relative.isEmpty) {
      if (entry.isDirectory) continue;
      throw const FormatException('Empty backup path');
    }
    final target = p.normalize(p.join(root.path, relative));
    if (!p.isWithin(p.absolute(root.path), p.absolute(target)) ||
        entries.containsKey(relative.toLowerCase())) {
      throw const FormatException('Conflicting backup path');
    }
    if (entry.size < 0) {
      throw const FormatException('Invalid backup entry size');
    }
    totalSize += entry.size;
    if (totalSize > 256 * 1024 * 1024 || entries.length >= 10000) {
      throw const FormatException('Backup exceeds extraction limit');
    }
    entries[relative.toLowerCase()] = entry;
  }
  for (final name in entries.keys) {
    var parent = p.posix.dirname(name);
    while (parent != '.') {
      if (entries[parent]?.isFile == true) {
        throw const FormatException('Backup file used as a directory');
      }
      parent = p.posix.dirname(parent);
    }
  }
  await root.create(recursive: true);
  for (final entry in entries.values) {
    final target = p.join(
      root.path,
      p.posix.normalize(entry.name.replaceAll('\\', '/')),
    );
    if (entry.isDirectory) {
      await Directory(target).create(recursive: true);
    } else {
      await File(target).parent.create(recursive: true);
      final output = _BoundedBackupOutput(target, entry.size);
      try {
        entry.writeContent(output);
        if (output.length != entry.size) {
          throw const FormatException('Backup entry size mismatch');
        }
      } finally {
        await output.close();
      }
    }
  }
}

class _BoundedBackupOutput extends OutputFileStream {
  _BoundedBackupOutput(String path, this.maximum)
    : super.withFileHandle(FileHandle(path, mode: FileAccess.write));
  final int maximum;
  void _check(int count) {
    if (count < 0 || length + count > maximum) {
      throw const FormatException('Backup entry exceeds its declared size');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }
}

/// File half of a restore transaction. Its rollback directory is on the same
/// filesystem as application data and is retained if rollback itself fails.
class RestoreFileTransaction {
  final Directory home;
  final Map<String, String> files;
  Directory? _backup;
  final List<({String target, String? original})> _installed = [];

  RestoreFileTransaction({required this.home, required this.files});

  Future<void> replace() async {
    final root = p.absolute(home.path);
    if (await FileSystemEntity.type(root, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException('Restore home is a link');
    }
    final destinations = <String>{};
    for (final entry in files.entries) {
      if (!p.isWithin(root, p.absolute(entry.value)) ||
          p.equals(p.absolute(entry.key), p.absolute(entry.value)) ||
          !destinations.add(p.absolute(entry.value).toLowerCase()) ||
          await FileSystemEntity.type(entry.key, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const FileSystemException('Invalid restore attachment');
      }
      var current = p.absolute(entry.value);
      while (current != root) {
        if (await FileSystemEntity.type(current, followLinks: false) ==
            FileSystemEntityType.link) {
          throw const FileSystemException('Restore target contains a link');
        }
        current = p.dirname(current);
      }
    }
    await home.create(recursive: true);
    _backup = await home.createTemp('.restore-rollback-');
    var index = 0;
    for (final entry in files.entries) {
      final target = File(entry.value);
      await target.parent.create(recursive: true);
      final temporary = File(
        p.join(
          target.parent.path,
          '.${p.basename(_backup!.path)}-${index++}.tmp',
        ),
      );
      try {
        await File(entry.key).copy(temporary.path);
        final type = await FileSystemEntity.type(
          target.path,
          followLinks: false,
        );
        String? original;
        if (type != FileSystemEntityType.notFound) {
          if (type != FileSystemEntityType.file) {
            throw const FileSystemException('Restore target is not a file');
          }
          original = p.join(_backup!.path, index.toString());
          await target.rename(original);
        }
        _installed.add((target: target.path, original: original));
        await temporary.rename(target.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }
  }

  Future<void> rollback() async {
    Object? firstError;
    StackTrace? firstStack;
    for (final entry in _installed.reversed) {
      try {
        final target = File(entry.target);
        if (await target.exists()) await target.delete();
        if (entry.original != null) {
          await File(entry.original!).rename(entry.target);
        }
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
    _installed.clear();
    await cleanup();
  }

  Future<bool> cleanup() async {
    try {
      if (_backup != null && await _backup!.exists()) {
        await _backup!.delete(recursive: true);
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
