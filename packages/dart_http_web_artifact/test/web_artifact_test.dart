import 'dart:convert';
import 'dart:io';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:dart_http_web_artifact/dart_http_web_artifact.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dart-http-web-artifact-');
    await File('${directory.path}/index.html').writeAsString('<h1>Console</h1>');
    await Directory('${directory.path}/assets').create();
    await File('${directory.path}/assets/main.js').writeAsString('console.log("plain");');
    await File('${directory.path}/assets/main.js.gz')
        .writeAsBytes(gzip.encode(utf8.encode('gzip')));
    await File('${directory.path}/assets/main.js.br').writeAsBytes(<int>[1, 2, 3]);
    await File('${directory.path}/Geist%5Bwght%5D.ttf').writeAsBytes(<int>[4, 5, 6]);
  });

  tearDown(() => directory.delete(recursive: true));

  test('mounts an entry point and catch-all route as internal routes', () {
    final router = Router<void>();
    router.serveWebArtifact(WebArtifact.directory(directory.path));

    expect(router.routeRegistry.registrations, hasLength(2));
    expect(router.routeRegistry.registrations[0].httpPath, '/');
    expect(router.routeRegistry.registrations[1].httpPath, '/<dart_http_web_artifact_path*>');
    for (final registration in router.routeRegistry.registrations) {
      expect(registration.exposure, RouteExposure.internal);
    }
  });

  test('streams ordinary assets with MIME, cache, and validation headers', () async {
    final artifact = WebArtifact.directory(directory.path);
    final context = RequestContext<void>(services: null);

    final response = await artifact.serve(context, 'assets/main.js');

    expect(response, isA<BinaryStreamResponse>());
    final stream = response as BinaryStreamResponse;
    expect(stream.contentType, 'text/javascript; charset=utf-8');
    expect(utf8.decode(await _bytes(stream.body)), 'console.log("plain");');
    expect(_header(stream.headers, 'cache-control'), 'public, max-age=3600');
    expect(_header(stream.headers, 'etag'), isNotEmpty);
    expect(_header(stream.headers, 'x-content-type-options'), 'nosniff');
  });

  test('prefers Brotli then gzip according to accepted quality', () async {
    final artifact = WebArtifact.directory(directory.path);
    final brotliContext = RequestContext<void>(
      services: null,
      req: RequestInput(headersMap: const {'accept-encoding': 'gzip, br'}),
    );
    final gzipContext = RequestContext<void>(
      services: null,
      req: RequestInput(headersMap: const {'accept-encoding': 'br;q=0, gzip;q=0.5'}),
    );

    final brotli = await artifact.serve(brotliContext, 'assets/main.js') as BinaryStreamResponse;
    final gzipResponse =
        await artifact.serve(gzipContext, 'assets/main.js') as BinaryStreamResponse;

    expect(_header(brotli.headers, 'content-encoding'), 'br');
    expect(await _bytes(brotli.body), <int>[1, 2, 3]);
    expect(_header(gzipResponse.headers, 'content-encoding'), 'gzip');
    expect(gzip.decode(await _bytes(gzipResponse.body)), utf8.encode('gzip'));
  });

  test('falls back to the entry point only for SPA navigation paths', () async {
    final artifact = WebArtifact.directory(directory.path, spaFallback: true);

    final navigation = await artifact.serve(
      RequestContext<void>(services: null),
      'containers/example',
    ) as BinaryStreamResponse;
    final missingAsset = await artifact.serve(
      RequestContext<void>(services: null),
      'assets/missing.js',
    );

    expect(utf8.decode(await _bytes(navigation.body)), '<h1>Console</h1>');
    expect(_header(navigation.headers, 'cache-control'), 'no-cache');
    expect((missingAsset as RawResponse).status, HttpStatus.notFound);
  });

  test('addresses encoded build filenames after URL decoding', () async {
    final artifact = WebArtifact.directory(directory.path);
    final response = await artifact.serve(
      RequestContext<void>(services: null),
      'Geist[wght].ttf',
    ) as BinaryStreamResponse;

    expect(await _bytes(response.body), <int>[4, 5, 6]);
  });

  test('rejects direct and percent-encoded traversal', () async {
    final artifact = WebArtifact.directory(directory.path, spaFallback: true);

    final direct = await artifact.serve(RequestContext<void>(services: null), '../secret');
    final encoded = await artifact.serve(RequestContext<void>(services: null), '%2e%2e/secret');

    expect((direct as RawResponse).status, HttpStatus.badRequest);
    expect((encoded as RawResponse).status, HttpStatus.badRequest);
  });

  test('returns 304 when the representation validator matches', () async {
    final artifact = WebArtifact.directory(directory.path);
    final first = await artifact.serve(
      RequestContext<void>(services: null),
      'assets/main.js',
    ) as BinaryStreamResponse;
    final etag = _header(first.headers, 'etag')!;

    final second = await artifact.serve(
      RequestContext<void>(services: null, req: RequestInput(headersMap: {'if-none-match': etag})),
      'assets/main.js',
    );

    expect((second as RawResponse).status, HttpStatus.notModified);
  });
}

Future<List<int>> _bytes(Stream<List<int>> stream) async => <int>[
  await for (final chunk in stream) ...chunk,
];

String? _header(List<HttpHeader> headers, String name) {
  for (final header in headers) {
    if (header.name.toLowerCase() == name) return header.value;
  }
  return null;
}
