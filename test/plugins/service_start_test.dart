import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('$packageName/service');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final service = Service();
  late int requestId;

  setUp(() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        requestId = (call.arguments as Map)['requestId'] as int;
      }
      return true;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> completed(int id, bool started) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('startCompleted', {'requestId': id, 'started': started}),
      ),
      (_) {},
    );
  }

  test(
    'queued ACK does not complete start; actual native failure does',
    () async {
      var settled = false;
      final operation = service.start().then((value) {
        settled = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(settled, false);
      await completed(requestId, false);
      expect(await operation, false);
    },
  );

  test('only matching completion makes the service ready', () async {
    var settled = false;
    final operation = service.start().then((value) {
      settled = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    await completed(requestId - 1, true);
    expect(settled, false);
    await completed(requestId, true);
    expect(await operation, true);
  });

  test('stop releases a pending start and ignores late success', () async {
    final operation = service.start();
    await Future<void>.delayed(Duration.zero);
    final oldId = requestId;
    await service.stop();
    expect(await operation, false);
    await completed(oldId, true);
  });

  test(
    'missing completion is bounded and cancellation is correlated',
    () async {
      int? cancelled;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') {
          requestId = (call.arguments as Map)['requestId'] as int;
        }
        if (call.method == 'cancelStart') {
          cancelled = (call.arguments as Map)['requestId'] as int;
        }
        return true;
      });
      expect(
        await service.start(timeout: const Duration(milliseconds: 20)),
        false,
      );
      expect(cancelled, requestId);
    },
  );
}
