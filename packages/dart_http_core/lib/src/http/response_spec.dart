import 'package:json_schema/json_schema.dart';

/// Declares the default response encoding for a successful route result.
final class ResponseSpec {
  const ResponseSpec._({required this.status, required this.contentType, this.schema});

  /// HTTP status code emitted for the response.
  final int status;

  /// Response content type.
  final String contentType;

  /// Optional schema used for documentation or validation.
  final JsonSchema? schema;

  /// Creates a JSON response specification.
  const ResponseSpec.json({int status = 200, JsonSchema? schema})
    : this._(status: status, contentType: 'application/json; charset=utf-8', schema: schema);

  /// Creates a plain-text response specification.
  const ResponseSpec.text({int status = 200})
    : this._(status: status, contentType: 'text/plain; charset=utf-8');

  /// Creates an HTML response specification.
  const ResponseSpec.html({int status = 200})
    : this._(status: status, contentType: 'text/html; charset=utf-8');

  /// Creates a binary response specification.
  const ResponseSpec.binary({int status = 200, String contentType = 'application/octet-stream'})
    : this._(
        status: status,
        contentType: contentType,
        schema: const JsonSchema.string(format: 'binary'),
      );

  /// Creates a server-sent events response specification.
  const ResponseSpec.sse({int status = 200})
    : this._(status: status, contentType: 'text/event-stream; charset=utf-8');
}
