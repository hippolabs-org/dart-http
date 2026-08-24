import 'dart:convert';
import 'dart:io';

import 'observability_config.dart';
import 'observability_context.dart';

enum LogLevel {
  debug,
  info,
  warning,
  error;

  static LogLevel? parse(String? value) {
    return switch (value?.toLowerCase().trim()) {
      'debug' => LogLevel.debug,
      'info' => LogLevel.info,
      'warn' || 'warning' => LogLevel.warning,
      'error' => LogLevel.error,
      _ => null,
    };
  }
}

/// Sink for structured service log events.
abstract class JsonLogger {
  const JsonLogger();

  void log(
    LogLevel level,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  });

  void debug(String message, {Map<String, Object?> fields = const {}}) =>
      log(LogLevel.debug, message, fields: fields);
  void info(String message, {Map<String, Object?> fields = const {}}) =>
      log(LogLevel.info, message, fields: fields);
  void warning(String message, {Map<String, Object?> fields = const {}}) =>
      log(LogLevel.warning, message, fields: fields);
  void error(String message, {Map<String, Object?> fields = const {}}) =>
      log(LogLevel.error, message, fields: fields);
}

/// Writes one structured event per stdout line.
final class StdoutJsonLogger extends JsonLogger {
  StdoutJsonLogger(this.config, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final ObservabilityConfig config;
  final DateTime Function() _clock;

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    if (level.index < config.logLevel.index) return;
    stdout.writeln(
      jsonEncode(<String, Object?>{
        'timestamp': _clock().toUtc().toIso8601String(),
        'level': level.name,
        'message': message,
        'service': config.serviceName,
        'version': config.serviceVersion,
        'environment': config.environment,
        ...?ObservabilityContext.current?.toFields(),
        ...fields,
      }),
    );
  }
}

final class TeeJsonLogger extends JsonLogger {
  const TeeJsonLogger(this.loggers);

  final List<JsonLogger> loggers;

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    for (final logger in loggers) {
      logger.log(level, message, fields: fields);
    }
  }
}
