typedef DartHttpEncoder<T> = Object? Function(T value);
typedef DartHttpDecoder<T> = T Function(Object? value);

/// Codec used by the runtime to decode schema-backed request values.
final class DartHttpCodec<T> {
  const DartHttpCodec({required this.encode, required this.decode});

  final DartHttpEncoder<T> encode;
  final DartHttpDecoder<T> decode;
}

/// Registry of schema-id keyed codecs used by the runtime.
final class DartHttpCodecRegistry {
  const DartHttpCodecRegistry([
    Map<String, ErasedDartHttpCodec> codecs = const <String, ErasedDartHttpCodec>{},
  ]) : _codecs = codecs;

  final Map<String, ErasedDartHttpCodec> _codecs;

  static const empty = DartHttpCodecRegistry();

  /// Returns a copy of the registry with [codec] registered for [schemaId].
  DartHttpCodecRegistry withCodec<T>(String schemaId, DartHttpCodec<T> codec) {
    return DartHttpCodecRegistry({
      ..._codecs,
      schemaId: ErasedDartHttpCodec(
        encode: (value) => codec.encode(value as T),
        decode: codec.decode,
      ),
    });
  }

  /// Whether a runtime codec has been registered for [schemaId].
  bool contains(String schemaId) => _codecs.containsKey(schemaId);

  /// Encodes [value] using the codec registered for [schemaId], when present.
  Object? encodeValue(String schemaId, Object? value) {
    if (value == null) {
      return null;
    }

    final codec = _codecs[schemaId];
    if (codec == null) {
      return value;
    }

    return codec.encode(value);
  }

  /// Decodes [value] using the codec registered for [schemaId].
  T decodeValue<T>(String schemaId, Object? value) {
    final codec = _codecs[schemaId];
    if (codec == null) {
      throw StateError('No runtime codec registered for schema "$schemaId".');
    }

    return codec.decode(value) as T;
  }

  /// Decodes [value] when a codec exists for [schemaId], otherwise returns it.
  Object? decodeValueOrRaw(String? schemaId, Object? value) {
    if (schemaId == null || value == null) {
      return value;
    }

    final codec = _codecs[schemaId];
    if (codec == null) {
      return value;
    }

    return codec.decode(value);
  }
}

final class ErasedDartHttpCodec {
  const ErasedDartHttpCodec({required this.encode, required this.decode});

  final Object? Function(Object? value) encode;
  final Object? Function(Object? value) decode;
}
