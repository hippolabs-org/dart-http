/// Durable client checkpoint for one upload resource.
final class ResumableUploadCheckpoint {
  const ResumableUploadCheckpoint({
    required this.uploadUri,
    required this.offset,
    required this.totalBytes,
    this.complete = false,
    this.protocolInteropVersion = 9,
  }) : assert(offset >= 0),
       assert(totalBytes >= 0),
       assert(offset <= totalBytes);

  final Uri uploadUri;
  final int offset;
  final int totalBytes;
  final bool complete;
  final int protocolInteropVersion;

  double get fraction => complete || totalBytes == 0 ? 1 : offset / totalBytes;

  ResumableUploadCheckpoint copyWith({int? offset, bool? complete}) {
    return ResumableUploadCheckpoint(
      uploadUri: uploadUri,
      offset: offset ?? this.offset,
      totalBytes: totalBytes,
      complete: complete ?? this.complete,
      protocolInteropVersion: protocolInteropVersion,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'upload_uri': uploadUri.toString(),
    'offset': offset,
    'total_bytes': totalBytes,
    'complete': complete,
    'protocol_interop_version': protocolInteropVersion,
  };

  factory ResumableUploadCheckpoint.fromJson(Map<String, Object?> json) {
    return ResumableUploadCheckpoint(
      uploadUri: Uri.parse(json['upload_uri']! as String),
      offset: json['offset']! as int,
      totalBytes: json['total_bytes']! as int,
      complete: json['complete'] as bool? ?? false,
      protocolInteropVersion: json['protocol_interop_version'] as int? ?? 9,
    );
  }
}
