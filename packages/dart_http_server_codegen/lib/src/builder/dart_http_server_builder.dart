import 'package:build/build.dart';
import 'package:dart_style/dart_style.dart';
import 'package:source_gen/source_gen.dart';

import 'from_schema_model_builder.dart';

const _fromHttpSchemaChecker = TypeChecker.typeNamedLiterally('FromHttpSchema');
const _fromMultipartSchemaChecker = TypeChecker.typeNamedLiterally('FromMultipartSchema');

/// Turns Dart HTTP schema annotations into request and response models.
final class DartHttpServerBuilderGenerator extends Generator {
  const DartHttpServerBuilderGenerator({
    this._formatterOptions = const FromSchemaFormatterOptions(),
  });

  factory DartHttpServerBuilderGenerator.fromOptions(BuilderOptions options) {
    final config = options.config;
    return DartHttpServerBuilderGenerator(
      formatterOptions: FromSchemaFormatterOptions(
        pageWidth: _optionalPositiveInt(config, 'page_width'),
        trailingCommas: _optionalTrailingCommas(config, 'trailing_commas'),
      ),
    );
  }

  final FromSchemaFormatterOptions _formatterOptions;

  String formatOutput(String code) {
    return _formatterOptions.createFormatter().format(code);
  }

  @override
  String? generate(LibraryReader library, BuildStep buildStep) {
    final multipartModels = library.annotatedWith(
      _fromMultipartSchemaChecker,
      throwOnUnresolved: false,
    );
    final httpModels = library.annotatedWith(_fromHttpSchemaChecker, throwOnUnresolved: false);
    if (httpModels.isEmpty && multipartModels.isEmpty) {
      return null;
    }

    final models = [
      for (final annotatedModel in httpModels)
        buildFromSchemaModel(annotatedModel.element, annotatedModel.annotation),
      for (final annotatedModel in multipartModels)
        buildFromSchemaModel(
          annotatedModel.element,
          annotatedModel.annotation,
          source: FromSchemaModelSource.multipart,
        ),
    ];

    return generateFromSchemaModels(models, formatterOptions: _formatterOptions);
  }
}

int? _optionalPositiveInt(Map<String, dynamic> config, String key) {
  final value = config[key];
  if (value == null) {
    return null;
  }
  if (value is int && value > 0) {
    return value;
  }
  throw ArgumentError.value(value, key, 'must be a positive integer');
}

TrailingCommas? _optionalTrailingCommas(Map<String, dynamic> config, String key) {
  final value = config[key];
  return switch (value) {
    null => null,
    'automate' => TrailingCommas.automate,
    'preserve' => TrailingCommas.preserve,
    _ => throw ArgumentError.value(value, key, 'must be "automate" or "preserve"'),
  };
}
