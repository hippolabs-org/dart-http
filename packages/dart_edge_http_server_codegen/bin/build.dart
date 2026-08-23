import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln('''
Runs build_runner for Dart Edge HTTP code generation.

Usage:
  dart run dart_edge_http_server_codegen:build [build_runner args]

Examples:
  dart run dart_edge_http_server_codegen:build
  dart run dart_edge_http_server_codegen:build --delete-conflicting-outputs
  dart run dart_edge_http_server_codegen:build watch
''');
    return;
  }

  final explicitCommand = args.firstOrNull;
  final command = explicitCommand == 'watch' ? 'watch' : 'build';
  final forwardedArgs = explicitCommand == 'watch' || explicitCommand == 'build'
      ? args.skip(1)
      : args;
  final result = await Process.start(Platform.resolvedExecutable, [
    'run',
    'build_runner',
    command,
    ...forwardedArgs,
  ], mode: ProcessStartMode.inheritStdio);

  exitCode = await result.exitCode;
}
