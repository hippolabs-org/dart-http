String joinRoutePath(String prefix, String path) {
  final normalizedPrefix = normalizeRoutePath(prefix);
  final normalizedPath = normalizeRoutePath(path);

  if (normalizedPrefix == '/') {
    return normalizedPath;
  }
  if (normalizedPath == '/') {
    return normalizedPrefix;
  }

  return '$normalizedPrefix$normalizedPath';
}

String normalizeRoutePath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty || trimmed == '/') {
    return '/';
  }

  final withoutTrailingSlash = trimmed.endsWith('/')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
  return withoutTrailingSlash.startsWith('/') ? withoutTrailingSlash : '/$withoutTrailingSlash';
}
