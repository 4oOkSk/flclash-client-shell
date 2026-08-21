import 'package:fl_clash/common/private_client_account.dart';
import 'package:test/test.dart';

void main() {
  test('parses a valid account summary', () {
    final info = PrivateClientAccountInfo.tryParse(
      '{"remaining_bytes":12345678,"expire_at":1800000000}',
    );

    expect(info, isNotNull);
    expect(info!.remainingBytes, 12345678);
    expect(info.expireAt, 1800000000);
  });

  test('rejects missing, malformed, or negative account summaries', () {
    expect(PrivateClientAccountInfo.tryParse(''), isNull);
    expect(PrivateClientAccountInfo.tryParse('{}'), isNull);
    expect(
      PrivateClientAccountInfo.tryParse(
        '{"remaining_bytes":-1,"expire_at":1800000000}',
      ),
      isNull,
    );
  });
}
