import 'dart:io';

import 'package:dart_http_core/dart_http_core.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

const _artifactPathParameter = 'dart_http_web_artifact_path';

/// A directory containing a prebuilt web application.
final class WebArtifact {
  WebArtifact.directory(
    String path, {
    this.entryPoint = 'index.html',
    this.spaFallback = false,
    this.precompressed = true,
    this.entryPointCacheControl = 'no-cache',
    this.assetCacheControl = 'public, max-age=3600',
    Map<String, String> headers = const <String, String>{},
  }) : directory = Directory(path).absolute,
       headers = Map<String, String>.unmodifiable(headers);

  /// Root directory of the built web artifact.
  final Directory directory;

  /// File returned for the mount root and for SPA navigation fallbacks.
  final String entryPoint;

  /// Whether extensionless missing paths fall back to [entryPoint].
  final bool spaFallback;

  /// Whether `.br` and `.gz` siblings may be served after negotiation.
  final bool precompressed;

  /// Cache policy for [entryPoint] and SPA navigation fallbacks.
  final String entryPointCacheControl;

  /// Cache policy for ordinary artifact files.
  final String assetCacheControl;

  /// Headers attached to every artifact response.
  final Map<String, String> headers;

  Future<String>? _resolvedRoot;

  /// Resolves and serves [relativePath] for one Dart HTTP request.
  Future<Object> serve<TServices>(RequestContext<TServices> context, String relativePath) async {
    final segments = _safeSegments(relativePath);
    if (segments == null) {
      return context.res.status(HttpStatus.badRequest).text('Invalid artifact path.');
    }

    final root = await _resolveRoot();
    var resolved = await _findFile(root, segments);
    var entryPointResponse = false;
    if (resolved == null) {
      if (!spaFallback || _looksLikeAsset(relativePath)) {
        return context.res.status(HttpStatus.notFound).text('Not found.');
      }
      resolved = await _findFile(root, <String>[entryPoint]);
      entryPointResponse = true;
    } else {
      entryPointResponse = p.equals(resolved.path, p.join(root, entryPoint));
    }

    if (resolved == null) {
      return context.res.status(HttpStatus.serviceUnavailable).text('Web artifact is unavailable.');
    }

    final representation = precompressed
        ? await _selectRepresentation(root, resolved, context.req.header('accept-encoding'))
        : _WebArtifactRepresentation(resolved);
    final stat = await representation.file.stat();
    final etag = _etag(stat, representation.encoding);
    final contentType = _contentType(resolved.path);
    final cacheControl = entryPointResponse ? entryPointCacheControl : assetCacheControl;

    _applyHeaders(
      context.res,
      cacheControl: cacheControl,
      etag: etag,
      modified: stat.modified,
      encoding: representation.encoding,
    );
    if (context.req.header('if-none-match') == etag) {
      return context.res.status(HttpStatus.notModified).encoded(contentType: contentType);
    }

    return context.res.binaryStream(
      contentType: contentType,
      body: representation.file.openRead(),
      contentLength: stat.size,
    );
  }

  Future<String> _resolveRoot() {
    return _resolvedRoot ??= () async {
      try {
        return await directory.resolveSymbolicLinks();
      } on FileSystemException {
        return p.canonicalize(directory.path);
      }
    }();
  }

  Future<File?> _findFile(String root, List<String> segments) async {
    for (final candidateSegments in _candidateSegments(segments)) {
      final candidate = File(p.joinAll(<String>[root, ...candidateSegments]));
      if (!await candidate.exists()) continue;

      final resolved = await candidate.resolveSymbolicLinks();
      if (!p.equals(resolved, root) && !p.isWithin(root, resolved)) continue;
      return File(resolved);
    }
    return null;
  }

  Future<_WebArtifactRepresentation> _selectRepresentation(
    String root,
    File file,
    String? acceptEncoding,
  ) async {
    final accepted = _acceptedContentEncodings(acceptEncoding);
    for (final encoding in accepted) {
      final suffix = encoding == 'br' ? '.br' : '.gz';
      final compressed = File('${file.path}$suffix');
      if (await compressed.exists()) {
        final resolved = await compressed.resolveSymbolicLinks();
        if (p.equals(resolved, root) || p.isWithin(root, resolved)) {
          return _WebArtifactRepresentation(File(resolved), encoding: encoding);
        }
      }
    }
    return _WebArtifactRepresentation(file);
  }

  void _applyHeaders(
    ResponseBuilder response, {
    required String cacheControl,
    required String etag,
    required DateTime modified,
    required String? encoding,
  }) {
    final defaults = <String, String>{
      'Cache-Control': cacheControl,
      'ETag': etag,
      'Last-Modified': HttpDate.format(modified.toUtc()),
      'X-Content-Type-Options': 'nosniff',
      if (precompressed) 'Vary': 'Accept-Encoding',
      'Content-Encoding': ?encoding,
    };
    final overridden = headers.keys.map((name) => name.toLowerCase()).toSet();
    for (final entry in defaults.entries) {
      if (!overridden.contains(entry.key.toLowerCase())) {
        response.header(entry.key, entry.value);
      }
    }
    for (final entry in headers.entries) {
      response.header(entry.key, entry.value);
    }
  }
}

/// Mounts [artifact] at [path] on this router.
extension WebArtifactRouter<TServices> on Router<TServices> {
  void serveWebArtifact(WebArtifact artifact, {String path = '/', List<Guard<TServices>>? guards}) {
    final mountPath = _mountPath(path);
    final artifactRouter = router('', exposure: RouteExposure.internal);
    final options = const RouteOptions(
      exposure: RouteExposure.internal,
      success: ResponseSpec.binary(),
    );
    artifactRouter.get(
      mountPath,
      options: options,
      guards: guards,
      handler: (context) => artifact.serve(context, artifact.entryPoint),
    );
    artifactRouter.get(
      mountPath == '/' ? '/<$_artifactPathParameter*>' : '$mountPath/<$_artifactPathParameter*>',
      options: options,
      guards: guards,
      handler: (context) =>
          artifact.serve(context, context.req.param(_artifactPathParameter) ?? ''),
    );
  }
}

final class _WebArtifactRepresentation {
  const _WebArtifactRepresentation(this.file, {this.encoding});

  final File file;
  final String? encoding;
}

String _mountPath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty || trimmed == '/') return '/';
  final withLeadingSlash = trimmed.startsWith('/') ? trimmed : '/$trimmed';
  return withLeadingSlash.endsWith('/')
      ? withLeadingSlash.substring(0, withLeadingSlash.length - 1)
      : withLeadingSlash;
}

List<String>? _safeSegments(String relativePath) {
  final segments = relativePath.split('/').where((segment) => segment.isNotEmpty).toList();
  if (segments.any(_unsafeSegment)) return null;
  return segments;
}

bool _unsafeSegment(String segment) {
  if (segment == '.' || segment == '..' || segment.contains(r'\') || segment.contains('\u0000')) {
    return true;
  }
  try {
    final decoded = Uri.decodeComponent(segment);
    return decoded == '.' ||
        decoded == '..' ||
        decoded.contains('/') ||
        decoded.contains(r'\') ||
        decoded.contains('\u0000');
  } on FormatException {
    return false;
  }
}

Iterable<List<String>> _candidateSegments(List<String> segments) sync* {
  final emitted = <String>{};
  final candidates = <List<String>>[
    segments,
    _tryDecodeSegments(segments),
    segments.map(Uri.encodeComponent).toList(growable: false),
  ];
  for (final candidate in candidates) {
    if (candidate.isEmpty || candidate.any(_unsafeSegment)) continue;
    final key = candidate.join('\u0000');
    if (emitted.add(key)) yield candidate;
  }
}

List<String> _tryDecodeSegments(List<String> segments) {
  try {
    return segments.map(Uri.decodeComponent).toList(growable: false);
  } on FormatException {
    return const <String>[];
  }
}

bool _looksLikeAsset(String path) => path.split('/').last.contains('.');

String _contentType(String path) {
  final mimeType = lookupMimeType(path) ?? 'application/octet-stream';
  if (mimeType.startsWith('text/') ||
      mimeType == 'application/javascript' ||
      mimeType == 'application/json') {
    return '$mimeType; charset=utf-8';
  }
  return mimeType;
}

String _etag(FileStat stat, String? encoding) {
  final suffix = encoding == null ? '' : '-$encoding';
  return 'W/"${stat.size.toRadixString(16)}-${stat.modified.millisecondsSinceEpoch.toRadixString(16)}$suffix"';
}

List<String> _acceptedContentEncodings(String? header) {
  if (header == null || header.trim().isEmpty) return const <String>[];
  final quality = <String, double>{};
  for (final value in header.toLowerCase().split(',')) {
    final parts = value.split(';').map((part) => part.trim()).toList();
    if (parts.first.isEmpty) continue;
    var q = 1.0;
    for (final parameter in parts.skip(1)) {
      if (parameter.startsWith('q=')) q = double.tryParse(parameter.substring(2)) ?? 0;
    }
    quality[parts.first] = q.clamp(0, 1).toDouble();
  }

  double acceptedQuality(String encoding) => quality[encoding] ?? quality['*'] ?? 0;
  final encodings = <String>[
    'br',
    'gzip',
  ].where((encoding) => acceptedQuality(encoding) > 0).toList();
  encodings.sort((left, right) {
    final byQuality = acceptedQuality(right).compareTo(acceptedQuality(left));
    if (byQuality != 0) return byQuality;
    return <String>['br', 'gzip'].indexOf(left).compareTo(<String>['br', 'gzip'].indexOf(right));
  });
  return encodings;
}
