import 'package:dart_http_core/dart_http_core.dart';
import 'package:test/test.dart';

void main() {
  test('exposes typed raw maps and single-value helpers', () {
    final input = RequestInput(
      paramsMap: const {'id': '42'},
      queryMap: const {'search': 'Ada'},
      headersMap: const {'content-type': 'application/json'},
    );

    expect(input.paramsMap, {'id': '42'});
    expect(input.queryMap, {'search': 'Ada'});
    expect(input.headersMap, {'content-type': 'application/json'});
    expect(input.param('id'), '42');
    expect(input.queryParam('search'), 'Ada');
    expect(input.header('Content-Type'), 'application/json');
  });

  test('supports optional typed reads without exposing raw storage fields', () {
    final input = RequestInput(
      params: const {'id': '42'},
      query: const SearchQuery(search: 'Ada'),
      headers: const {'x-request-id': 'req_1'},
      body: const CreateUserInput(name: 'Ada'),
    );

    expect(input.hasParams<Map<String, String>>(), isTrue);
    expect(input.hasQuery<SearchQuery>(), isTrue);
    expect(input.hasHeaders<Map<String, String>>(), isTrue);
    expect(input.hasBody<CreateUserInput>(), isTrue);

    expect(input.maybeParams<Map<String, String>>(), {'id': '42'});
    expect(input.maybeQuery<SearchQuery>()?.search, 'Ada');
    expect(input.maybeHeaders<Map<String, String>>(), {'x-request-id': 'req_1'});
    expect(input.maybeBody<CreateUserInput>()?.name, 'Ada');
    expect(input.bodyOrNull, isA<CreateUserInput>());
  });

  test('derives raw maps from matching typed inputs when not provided', () {
    final input = RequestInput(
      params: const {'id': '42'},
      query: const {'search': 'Ada'},
      headers: const {'accept': 'application/json'},
    );

    expect(input.paramsMap, {'id': '42'});
    expect(input.queryMap, {'search': 'Ada'});
    expect(input.headersMap, {'accept': 'application/json'});
  });

  test('carries an opaque native body slot for runtime extensions', () {
    final input = RequestInput(nativeBody: const NativeBodyToken('body-1'));

    expect(input.nativeBodyOrNull, const NativeBodyToken('body-1'));
    expect(input.maybeNativeBody<NativeBodyToken>(), const NativeBodyToken('body-1'));
    expect(input.maybeNativeBody<String>(), isNull);
  });
}

final class SearchQuery {
  const SearchQuery({this.search});

  final String? search;
}

final class CreateUserInput {
  const CreateUserInput({required this.name});

  final String name;
}

final class NativeBodyToken {
  const NativeBodyToken(this.id);

  final String id;

  @override
  bool operator ==(Object other) {
    return other is NativeBodyToken && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
