class PrivateClientSelectionFailure implements Exception {
  final String outcome;
  final String? actualSelection;

  const PrivateClientSelectionFailure(this.outcome, this.actualSelection);

  @override
  String toString() => 'Server selection: $outcome';
}

Future<Map<String, String>> applyPrivateClientProxySelection({
  required Map<String, String> current,
  required String groupName,
  required String proxyName,
  required Future<String> Function(String proxyName) changeCore,
  required Future<String?> Function() readCore,
  required Future<bool> Function(Map<String, String> next) persist,
}) async {
  if (groupName.trim().isEmpty || proxyName.trim().isEmpty) {
    throw StateError('Invalid server selection');
  }
  final previous = await readCore();
  if (previous == null || previous.isEmpty) {
    throw const PrivateClientSelectionFailure('unconfirmed', null);
  }
  Future<String?> readBack() async {
    try {
      return await readCore();
    } catch (_) {
      return null;
    }
  }

  try {
    final message = await changeCore(proxyName);
    if (message.isNotEmpty) {
      throw PrivateClientSelectionFailure('rejected', await readBack());
    }
  } on PrivateClientSelectionFailure {
    rethrow;
  } catch (_) {
    final actual = await readBack();
    if (actual != proxyName) {
      throw PrivateClientSelectionFailure('unconfirmed', actual);
    }
  }
  final next = Map<String, String>.from(current)..[groupName] = proxyName;
  try {
    if (!await persist(next)) throw StateError('storage rejected');
  } catch (_) {
    try {
      await changeCore(previous);
    } catch (_) {}
    final actual = await readBack();
    throw PrivateClientSelectionFailure(
      actual == previous ? 'save-failed-restored' : 'save-failed-unconfirmed',
      actual,
    );
  }
  return Map<String, String>.unmodifiable(next);
}
