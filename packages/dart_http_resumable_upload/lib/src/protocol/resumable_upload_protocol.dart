/// Wire constants and codecs for the resumable upload protocol.
abstract final class ResumableUploadProtocol {
  /// Implemented IETF draft interoperability version.
  static const draftInteropVersion = 9;

  static const partialUploadMediaType = 'application/partial-upload';
  static const draftInteropVersionHeader = 'upload-draft-interop-version';
  static const offsetHeader = 'upload-offset';
  static const lengthHeader = 'upload-length';
  static const completeHeader = 'upload-complete';
  static const limitHeader = 'upload-limit';

  static String encodeBoolean(bool value) => value ? '?1' : '?0';

  static bool? parseBoolean(String? value) => switch (value?.trim()) {
    '?1' => true,
    '?0' => false,
    _ => null,
  };

  static int? parseNonNegativeInteger(String? value) {
    final parsed = int.tryParse(value?.trim() ?? '');
    return parsed != null && parsed >= 0 ? parsed : null;
  }

  /// Reads [name] case-insensitively from an HTTP header map.
  static String? header(Map<String, String> headers, String name) {
    final normalized = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == normalized) return entry.value;
    }
    return null;
  }
}
