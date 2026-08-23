import '../http/http_method.dart';
import 'route_options.dart';

/// Binds native HTTP route metadata to a native handler function.
final class NativeHttpRouteMount {
  const NativeHttpRouteMount({
    required this.method,
    required this.path,
    this.handlerPath,
    required this.options,
    required this.nativeHandle,
    required this.nativeHandlerAddress,
    required this.nativeFreeResponseAddress,
  });

  /// HTTP method accepted by the native route.
  final HttpMethod method;

  /// Route path pattern, for example `/auth/sign-in/email`.
  final String path;

  /// Path pattern passed to the native handler after route matching.
  ///
  /// When omitted, the handler receives the full public request path. Native
  /// backends that are mounted under an application prefix can use this to keep
  /// their own base path independent from the public router prefix.
  final String? handlerPath;

  /// Documentation and validation options for the route.
  final RouteOptions options;

  /// Opaque native instance handle passed to the handler.
  final int nativeHandle;

  /// Address of a native HTTP handler function.
  final int nativeHandlerAddress;

  /// Address of the function that frees responses from [nativeHandlerAddress].
  final int nativeFreeResponseAddress;
}
