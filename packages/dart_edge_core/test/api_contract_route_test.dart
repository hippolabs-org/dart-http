import 'package:dart_edge_core/dart_edge_core.dart';
import 'package:test/test.dart';

void main() {
  test('ApiEndpoint stores route metadata', () {
    const options = RouteOptions(operationId: 'listThings', success: ResponseSpec.json());

    const endpoint = ApiEndpoint(method: HttpMethod.post, path: '/things/list', options: options);

    expect(endpoint.method, HttpMethod.post);
    expect(endpoint.path, '/things/list');
    expect(endpoint.options, same(options));
  });

  test('ApiContractRoute is metadata-only', () {
    const options = RouteOptions(operationId: 'listThings', success: ResponseSpec.json());

    final route = ApiContractRoute<Object?>(options);

    expect(route.options, same(options));
    expect(() => route.handle(RequestContext<Object?>(services: null)), throwsUnsupportedError);
  });
}
