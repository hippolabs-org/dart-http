import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:test/test.dart';

void main() {
  group('DartHttpClientBase.invoke buffered bodies', () {
    test('binary success with invalid UTF-8 keeps raw bytes intact', () async {
      final bytes = Uint8List.fromList(<int>[0xff, 0xfe, 0x00, 0xc3, 0x28, 0x80]);
      final client = _Client(
        DartHttpClientResponse.ownedBytes(
          status: 200,
          contentType: 'application/octet-stream',
          bodyBytes: bytes,
        ),
      );

      final result = await client.invoke(
        const DartHttpClientInvocation<Uint8List, Object?, Object?, Object?, Object?>(
          method: HttpMethod.get,
          pathTemplate: '/blob',
          success: DartHttpClientResponseSpec<Uint8List>(
            status: 200,
            contentType: 'application/octet-stream',
            responseMode: DartHttpClientResponseMode.buffered,
          ),
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.rawBodyBytes, same(bytes));
      expect(result.data, same(bytes));
      expect(result.rawBody, utf8.decode(bytes, allowMalformed: true));
      expect(result.rawBody, same(result.rawBody));
    });

    test('decodes JSON from bytes and exposes text on demand', () async {
      final client = _Client(
        DartHttpClientResponse.ownedBytes(
          status: 200,
          contentType: 'application/json',
          bodyBytes: Uint8List.fromList(utf8.encode('{"name":"Grüße"}')),
        ),
      );

      final result = await client.invoke(
        const DartHttpClientInvocation<Object?, Object?, Object?, Object?, Object?>(
          method: HttpMethod.get,
          pathTemplate: '/item',
          success: DartHttpClientResponseSpec<Object?>(
            status: 200,
            contentType: 'application/json',
            responseMode: DartHttpClientResponseMode.buffered,
          ),
        ),
      );

      expect(result.data, {'name': 'Grüße'});
      expect(result.rawBody, '{"name":"Grüße"}');
    });

    test('error responses decode JSON bodies and keep raw text', () async {
      final client = _Client(
        DartHttpClientResponse.ownedBytes(
          status: 404,
          contentType: 'application/json',
          bodyBytes: Uint8List.fromList(utf8.encode('{"code":"missing"}')),
        ),
      );

      final result = await client.invoke(
        const DartHttpClientInvocation<Object?, Object?, Object?, Object?, Object?>(
          method: HttpMethod.get,
          pathTemplate: '/item',
          success: DartHttpClientResponseSpec<Object?>(
            status: 200,
            contentType: 'application/json',
            responseMode: DartHttpClientResponseMode.buffered,
          ),
          errors: [DartHttpClientErrorSpec(status: 404, code: 'missing')],
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.error!.body, {'code': 'missing'});
      expect(result.error!.rawBody, '{"code":"missing"}');
      expect(result.rawBody, '{"code":"missing"}');
    });

    test('response objects built from text still expose bytes', () {
      const response = DartHttpClientResponseObject<String>(
        status: 200,
        contentType: 'text/plain',
        rawBody: 'hé',
      );
      expect(response.rawBody, 'hé');
      expect(response.rawBodyBytes, utf8.encode('hé'));
    });
  });
}

final class _Client extends DartHttpClientBase {
  _Client(DartHttpClientResponse response)
    : super(baseUri: Uri.parse('http://localhost'), transport: _Transport(response));
}

final class _Transport implements HttpClientTransport {
  _Transport(this.response);

  final DartHttpClientResponse response;

  @override
  Future<DartHttpClientResponse> send(DartHttpClientRequest request) async => response;

  @override
  Future<DartHttpClientStreamedResponse> sendStream(DartHttpClientRequest request) =>
      throw UnimplementedError();
}
