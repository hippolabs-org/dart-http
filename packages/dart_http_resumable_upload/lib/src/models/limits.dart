/// Limits advertised by a resumable upload server.
final class ResumableUploadLimits {
  const ResumableUploadLimits({
    this.maxSize,
    this.minSize,
    this.minAppendSize,
    this.maxAppendSize = 8 * 1024 * 1024,
    this.maxAge,
  }) : assert(maxSize == null || maxSize >= 0),
       assert(minSize == null || minSize >= 0),
       assert(minAppendSize == null || minAppendSize >= 0),
       assert(maxAppendSize > 0);

  final int? maxSize;
  final int? minSize;
  final int? minAppendSize;
  final int maxAppendSize;
  final Duration? maxAge;

  /// Parses the integer members defined for the `Upload-Limit` dictionary.
  ///
  /// Unknown members are ignored. An invalid known member invalidates the
  /// entire value, as required by the resumable upload draft.
  static ResumableUploadLimits? parse(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    int? maxSize;
    int? minSize;
    int? minAppendSize;
    int? maxAppendSize;
    Duration? maxAge;

    for (final rawMember in value.split(',')) {
      final member = rawMember.trim();
      final separator = member.indexOf('=');
      final key = (separator < 0 ? member : member.substring(0, separator)).trim().toLowerCase();
      const knownKeys = <String>{
        'max-size',
        'min-size',
        'min-append-size',
        'max-append-size',
        'max-age',
      };
      if (!knownKeys.contains(key)) continue;
      if (separator < 0) return null;
      final parsed = int.tryParse(member.substring(separator + 1).trim());
      if (parsed == null || parsed < 0) return null;
      switch (key) {
        case 'max-size':
          maxSize = parsed;
        case 'min-size':
          minSize = parsed;
        case 'min-append-size':
          minAppendSize = parsed;
        case 'max-append-size':
          if (parsed == 0) return null;
          maxAppendSize = parsed;
        case 'max-age':
          maxAge = Duration(seconds: parsed);
      }
    }

    return ResumableUploadLimits(
      maxSize: maxSize,
      minSize: minSize,
      minAppendSize: minAppendSize,
      maxAppendSize: maxAppendSize ?? 8 * 1024 * 1024,
      maxAge: maxAge,
    );
  }

  String toHeaderValue() => <String>[
    if (maxSize case final value?) 'max-size=$value',
    if (minSize case final value?) 'min-size=$value',
    if (minAppendSize case final value?) 'min-append-size=$value',
    'max-append-size=$maxAppendSize',
    if (maxAge case final value?) 'max-age=${value.inSeconds}',
  ].join(', ');
}
