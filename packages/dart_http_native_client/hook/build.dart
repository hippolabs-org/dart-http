import 'package:hippolabs_native_assets/hippolabs_native_assets.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    await const HippolabsRustBuilder(
      assetName: 'dart_http_native_client.dart',
      cratePath: 'rust',
      prebuilt: HippolabsRustPrebuilt.github(),
    ).run(input: input, output: output);
  });
}
