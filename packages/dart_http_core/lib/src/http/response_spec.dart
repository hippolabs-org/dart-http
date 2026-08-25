import 'package:json_schema/json_schema.dart';

/// Declares whether a successful response has special streaming semantics.
enum ResponseStreamingMode {
  /// The response has no protocol-specific streaming semantics.
  none,

  /// The response uses the server-sent events protocol.
  serverSentEvents,
}

/// Declares the default response encoding for a successful route result.
final class ResponseSpec {
  const ResponseSpec._({
    required this.status,
    required this.contentType,
    this.schema,
    this.streamingMode = ResponseStreamingMode.none,
  });

  /// HTTP status code emitted for the response.
  final int status;

  /// Response content type.
  final String contentType;

  /// Optional schema used for documentation or validation.
  final JsonSchema? schema;

  /// Protocol-specific streaming semantics for this response.
  final ResponseStreamingMode streamingMode;

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
    : this._(
        status: status,
        contentType: 'text/event-stream; charset=utf-8',
        streamingMode: ResponseStreamingMode.serverSentEvents,
      );
}
