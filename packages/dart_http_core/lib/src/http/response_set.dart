import 'error_response.dart';
import 'response_spec.dart';

/// Groups the success and documented error responses for a route.
final class ResponseSet {
  const ResponseSet({required this.success, this.errors = const <ErrorResponse>[]});

  /// The primary success response returned by the route.
  final ResponseSpec success;

  /// Additional documented non-success responses.
  final List<ErrorResponse> errors;
}
