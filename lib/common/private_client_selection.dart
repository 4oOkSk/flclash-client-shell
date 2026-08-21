Future<Map<String, String>> applyPrivateClientProxySelection({
  required Map<String, String> current,
  required String groupName,
  required String proxyName,
  required Future<String> Function() changeCore,
  required Future<bool> Function(Map<String, String> next) persist,
}) async {
  if (groupName.trim().isEmpty || proxyName.trim().isEmpty) {
    throw StateError('Invalid server selection');
  }
  final message = await changeCore();
  if (message.isNotEmpty) {
    throw StateError(message);
  }
  final next = Map<String, String>.from(current)..[groupName] = proxyName;
  if (!await persist(next)) {
    throw StateError('Server selection could not be saved');
  }
  return Map<String, String>.unmodifiable(next);
}
