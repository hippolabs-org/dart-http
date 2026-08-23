/// Reads a decoded JSON object as a string-keyed Dart map.
Map<String, Object?> readJsonObject(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  return Map<String, Object?>.from(value! as Map);
}
