import 'package:flutter_riverpod/flutter_riverpod.dart';

final clientConnectionReadyProvider =
    NotifierProvider<ClientConnectionReady, bool>(ClientConnectionReady.new);

class ClientConnectionReady extends Notifier<bool> {
  @override
  bool build() => false;

  void setReady(bool ready) => state = ready;
}
