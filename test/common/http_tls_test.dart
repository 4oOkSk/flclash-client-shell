import 'dart:io';
import 'package:fl_clash/common/http.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'HTTP rejects untrusted TLS and accepts an explicitly trusted certificate',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'client-tls-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final certificate = '${directory.path}/certificate.pem';
      final key = '${directory.path}/key.pem';
      final generated = await Process.run('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-days',
        '1',
        '-subj',
        '/CN=127.0.0.1',
        '-addext',
        'subjectAltName=IP:127.0.0.1',
        '-keyout',
        key,
        '-out',
        certificate,
      ]);
      expect(
        generated.exitCode,
        0,
        reason: 'OpenSSL is required for the local TLS regression',
      );
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        SecurityContext()
          ..useCertificateChain(certificate)
          ..usePrivateKey(key),
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write('ok');
        await request.response.close();
      }, onError: (Object _) {});
      final client = FlClashHttpOverrides().createHttpClient(null);
      addTearDown(() => client.close(force: true));
      final endpoint = Uri.parse('https://127.0.0.1:${server.port}/');
      await expectLater(
        client.getUrl(endpoint),
        throwsA(isA<HandshakeException>()),
      );
      final trusted = FlClashHttpOverrides().createHttpClient(
        SecurityContext()..setTrustedCertificates(certificate),
      );
      addTearDown(() => trusted.close(force: true));
      final response = await (await trusted.getUrl(endpoint)).close();
      expect(response.statusCode, 200);
      await response.drain<void>();
    },
  );
}
