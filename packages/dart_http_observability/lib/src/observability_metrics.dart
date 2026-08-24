import 'dart:io';

/// Small in-process Prometheus registry for service and domain metrics.
final class MetricsRegistry {
  MetricsRegistry({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      _startedAt = (clock ?? DateTime.now)();

  final DateTime Function() _clock;
  final DateTime _startedAt;
  final List<Metric> _metrics = <Metric>[];

  Counter counter(String name, {String help = '', List<String> labelNames = const []}) {
    final metric = Counter(name, help: help, labelNames: labelNames);
    _metrics.add(metric);
    return metric;
  }

  Gauge gauge(String name, {String help = '', List<String> labelNames = const []}) {
    final metric = Gauge(name, help: help, labelNames: labelNames);
    _metrics.add(metric);
    return metric;
  }

  Histogram histogram(
    String name, {
    String help = '',
    List<String> labelNames = const [],
    List<double> buckets = const [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  }) {
    final metric = Histogram(name, help: help, labelNames: labelNames, buckets: buckets);
    _metrics.add(metric);
    return metric;
  }

  String scrape() {
    final uptime = _clock().difference(_startedAt).inMilliseconds / 1000;
    return <String>[
      for (final metric in _metrics) metric.scrape(),
      '# HELP process_resident_memory_bytes Resident memory size in bytes.\n'
          '# TYPE process_resident_memory_bytes gauge\n'
          'process_resident_memory_bytes ${ProcessInfo.currentRss}\n'
          '# HELP process_uptime_seconds Process uptime in seconds.\n'
          '# TYPE process_uptime_seconds gauge\n'
          'process_uptime_seconds $uptime\n',
    ].join('\n');
  }
}

abstract class Metric {
  Metric(this.name, {required this.help, required List<String> labelNames})
    : labelNames = List<String>.unmodifiable(labelNames);

  final String name;
  final String help;
  final List<String> labelNames;

  String scrape();

  String encodeLabels(Map<String, String> values, {Map<String, String> extra = const {}}) {
    final labels = <String, String>{for (final name in labelNames) name: ?values[name], ...extra};
    if (labels.isEmpty) return '';
    return '{${labels.entries.map((entry) => '${entry.key}="${_escape(entry.value)}"').join(',')}}';
  }
}

final class Counter extends Metric {
  Counter(super.name, {required super.help, required super.labelNames});

  final Map<String, _MetricValue> _values = <String, _MetricValue>{};

  void inc({double value = 1, Map<String, String> labels = const {}}) {
    final key = _labelKey(labels);
    final metric = _values.putIfAbsent(key, () => _MetricValue(labels));
    metric.value += value;
  }

  @override
  String scrape() {
    final buffer = StringBuffer('# HELP $name $help\n# TYPE $name counter\n');
    for (final metric in _values.values) {
      buffer.writeln('$name${encodeLabels(metric.labels)} ${metric.value}');
    }
    return buffer.toString();
  }
}

final class Gauge extends Metric {
  Gauge(super.name, {required super.help, required super.labelNames});

  final Map<String, _MetricValue> _values = <String, _MetricValue>{};

  void inc({double value = 1, Map<String, String> labels = const {}}) => _change(value, labels);
  void dec({double value = 1, Map<String, String> labels = const {}}) => _change(-value, labels);
  void set(double value, {Map<String, String> labels = const {}}) {
    _values[_labelKey(labels)] = _MetricValue(labels)..value = value;
  }

  void _change(double value, Map<String, String> labels) {
    final metric = _values.putIfAbsent(_labelKey(labels), () => _MetricValue(labels));
    metric.value += value;
  }

  @override
  String scrape() {
    final buffer = StringBuffer('# HELP $name $help\n# TYPE $name gauge\n');
    for (final metric in _values.values) {
      buffer.writeln('$name${encodeLabels(metric.labels)} ${metric.value}');
    }
    return buffer.toString();
  }
}

final class Histogram extends Metric {
  Histogram(
    super.name, {
    required super.help,
    required super.labelNames,
    required List<double> buckets,
  }) : buckets = List<double>.unmodifiable(<double>[...buckets]..sort());

  final List<double> buckets;
  final Map<String, _HistogramValue> _values = <String, _HistogramValue>{};

  void observe(double value, {Map<String, String> labels = const {}}) {
    final metric = _values.putIfAbsent(_labelKey(labels), () => _HistogramValue(labels, buckets));
    metric
      ..count += 1
      ..sum += value;
    for (final bucket in buckets) {
      if (value <= bucket) metric.bucketCounts[bucket] = metric.bucketCounts[bucket]! + 1;
    }
  }

  @override
  String scrape() {
    final buffer = StringBuffer('# HELP $name $help\n# TYPE $name histogram\n');
    for (final metric in _values.values) {
      for (final entry in metric.bucketCounts.entries) {
        buffer.writeln(
          '${name}_bucket${encodeLabels(metric.labels, extra: {'le': _format(entry.key)})} ${entry.value}',
        );
      }
      buffer
        ..writeln(
          '${name}_bucket${encodeLabels(metric.labels, extra: const {'le': '+Inf'})} ${metric.count}',
        )
        ..writeln('${name}_sum${encodeLabels(metric.labels)} ${metric.sum}')
        ..writeln('${name}_count${encodeLabels(metric.labels)} ${metric.count}');
    }
    return buffer.toString();
  }
}

final class StandardHttpMetrics {
  StandardHttpMetrics(MetricsRegistry registry)
    : requests = registry.counter(
        'http_server_requests_total',
        help: 'HTTP requests by method, normalized route, and status.',
        labelNames: const ['method', 'route', 'status'],
      ),
      errors = registry.counter(
        'http_server_errors_total',
        help: 'HTTP errors by method, normalized route, and error name.',
        labelNames: const ['method', 'route', 'errorName'],
      ),
      duration = registry.histogram(
        'http_server_request_duration_seconds',
        help: 'Dart HTTP request handler duration in seconds.',
        labelNames: const ['method', 'route', 'status'],
      ),
      responseBodySize = registry.histogram(
        'http_server_response_body_bytes',
        help: 'HTTP response body size in bytes when known.',
        labelNames: const ['method', 'route', 'status'],
      ),
      activeRequests = registry.gauge(
        'http_server_active_requests',
        help: 'Active Dart HTTP requests by method and normalized route.',
        labelNames: const ['method', 'route'],
      );

  final Counter requests;
  final Counter errors;
  final Histogram duration;
  final Histogram responseBodySize;
  final Gauge activeRequests;
}

final class _MetricValue {
  _MetricValue(Map<String, String> labels) : labels = Map<String, String>.unmodifiable(labels);
  final Map<String, String> labels;
  double value = 0;
}

final class _HistogramValue {
  _HistogramValue(Map<String, String> labels, List<double> buckets)
    : labels = Map<String, String>.unmodifiable(labels),
      bucketCounts = <double, int>{for (final bucket in buckets) bucket: 0};
  final Map<String, String> labels;
  final Map<double, int> bucketCounts;
  double sum = 0;
  int count = 0;
}

String _labelKey(Map<String, String> labels) {
  final entries = labels.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  return entries.map((entry) => '${entry.key}=${entry.value}').join('\n');
}

String _escape(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('\n', r'\n').replaceAll('"', r'\"');
String _format(double value) => value == value.roundToDouble() ? '${value.toInt()}' : '$value';
