/// Parses `XMLHttpRequest.getAllResponseHeaders()` output.
///
/// Header names are lowercased. Repeated fields are joined with `, ` as
/// RFC 9110 allows, except `set-cookie`, whose values may contain commas
/// (`Expires`) and are therefore joined with `\n`.
Map<String, String> parseXhrResponseHeaders(String raw) {
  final headers = <String, String>{};
  for (final line in raw.split('\r\n')) {
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    final name = line.substring(0, separator).trim().toLowerCase();
    final value = line.substring(separator + 1).trim();
    final existing = headers[name];
    headers[name] = existing == null
        ? value
        : '$existing${name == 'set-cookie' ? '\n' : ', '}$value';
  }
  return headers;
}
