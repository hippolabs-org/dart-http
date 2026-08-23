import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'src/builder/dart_http_server_builder.dart';

/// Builder entrypoint used by `build_runner`.
Builder dartHttpServerBuilder(BuilderOptions options) {
  final generator = DartHttpServerBuilderGenerator.fromOptions(options);
  return SharedPartBuilder(
    [generator],
    'dart_http_server',
    formatOutput: (code, _) => generator.formatOutput(code),
  );
}
