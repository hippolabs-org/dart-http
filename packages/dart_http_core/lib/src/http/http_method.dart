/// Supported HTTP methods for [RouteOptions]s.
enum HttpMethod {
  get,
  post,
  put,
  patch,
  delete,
  head,
  options;

  String get wireName => switch (this) {
    .get => 'GET',
    .post => 'POST',
    .put => 'PUT',
    .patch => 'PATCH',
    .delete => 'DELETE',
    .head => 'HEAD',
    .options => 'OPTIONS',
  };
}
