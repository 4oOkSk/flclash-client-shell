import 'dart:convert';
import 'dart:io';

/// A scoped recovery journal, not permission to clear arbitrary system proxies.
class ProxyOwnershipStore {
  ProxyOwnershipStore([this.file]);
  final Future<File>? file;
  Map<String, dynamic>? _memory;

  Future<Map<String, dynamic>> read() async {
    if (_memory != null) return _memory!;
    final target = await file;
    if (target == null) return _memory = {};
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return _memory = {};
    if (type != FileSystemEntityType.file) {
      throw const FormatException('Invalid proxy recovery journal');
    }
    final value = jsonDecode(await target.readAsString());
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid proxy recovery journal');
    }
    return _memory = value;
  }

  Future<void> write(Map<String, dynamic> value) async {
    final target = await file;
    if (target != null) {
      await target.parent.create(recursive: true);
      final directory = await target.parent.createTemp('.proxy-journal-');
      try {
        final staged = File('${directory.path}/state.json');
        await staged.writeAsString(jsonEncode(value), flush: true);
        final secured = await Process.run('chmod', ['600', staged.path]);
        if (secured.exitCode != 0) {
          throw const FileSystemException('Unable to secure proxy journal');
        }
        await staged.rename(target.path);
      } finally {
        await directory.delete(recursive: true);
      }
    }
    _memory = value;
  }
}
