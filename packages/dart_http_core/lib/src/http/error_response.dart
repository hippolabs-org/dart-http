/// Declares one documented error response for a route.
final class ErrorResponse {
  const ErrorResponse({required this.status, this.code});

  /// The HTTP status code returned for the error.
  final int status;

  /// Optional stable application-level error code.
  final String? code;

  /// Convenience helper for a `401 Unauthorized` response.
  static ErrorResponse unauthorized({String? code}) {
    return ErrorResponse(status: 401, code: code);
  }

  /// Convenience helper for a `404 Not Found` response.
  static ErrorResponse notFound({String? code}) {
    return ErrorResponse(status: 404, code: code);
  }

  /// Convenience helper for a `409 Conflict` response.
  static ErrorResponse conflict({String? code}) {
    return ErrorResponse(status: 409, code: code);
  }
}
