import 'dart:async';

import '../context/request_context.dart';
import '../http/raw_response.dart';

/// Result of evaluating one [Guard].
final class GuardResult {
  const GuardResult.allow() : response = null;

  const GuardResult.deny(this.response);

  /// Optional response used to short-circuit the request.
  final RawResponse? response;

  /// Whether request handling should continue.
  bool get isAllowed => response == null;
}

/// Typed authorization guard evaluated before a route handler runs.
abstract interface class Guard<TServices> {
  /// Returns `allow` to continue or `deny` with a response to short-circuit.
  FutureOr<GuardResult> authorize(RequestContext<TServices> ctx);
}

/// Closure-backed guard handler.
typedef GuardHandler<TServices> = FutureOr<GuardResult> Function(RequestContext<TServices> ctx);

/// Concrete [Guard] backed by a closure.
final class HandlerGuard<TServices> implements Guard<TServices> {
  HandlerGuard({required this._handler, this.debugName});

  final GuardHandler<TServices> _handler;
  final String? debugName;

  @override
  FutureOr<GuardResult> authorize(RequestContext<TServices> ctx) {
    return _handler(ctx);
  }

  @override
  String toString() => debugName ?? 'HandlerGuard<$TServices>()';
}
