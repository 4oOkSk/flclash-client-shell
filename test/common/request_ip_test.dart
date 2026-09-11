import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/request.dart';
import 'package:flutter_test/flutter_test.dart';

class _IpAdapter implements HttpClientAdapter {
  final bool emptyFirst;
  final requested = <String>[];

  _IpAdapter({required this.emptyFirst});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri.toString());
    if (options.uri.host == 'ipwho.is') {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return ResponseBody.fromString(
        jsonEncode(
          emptyFirst
              ? {'success': false, 'message': 'Reserved range'}
              : {'ip': '192.0.2.1', 'country_code': 'ZZ'},
        ),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return ResponseBody.fromString(
      jsonEncode({'ip': '192.0.2.2', 'country_code': 'ZZ', 'cc': 'ZZ'}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('counts requests before first successful IP answer', () async {
    final adapter = _IpAdapter(emptyFirst: false);
    final client = Request();
    client.dio.httpClientAdapter = adapter;
    final response = await client.checkIp();
    expect(response.data?.ip, '192.0.2.1');
    expect(adapter.requested.length, 1);
    expect(adapter.requested.where((url) => url.startsWith('http:')).length, 0);
    client.dio.close(force: true);
  });

  test('HTTP 200 failure payload does not beat valid response', () async {
    final adapter = _IpAdapter(emptyFirst: true);
    final client = Request();
    client.dio.httpClientAdapter = adapter;
    final response = await client.checkIp();
    expect(response.data?.ip, '192.0.2.2');
    client.dio.close(force: true);
  });
}
