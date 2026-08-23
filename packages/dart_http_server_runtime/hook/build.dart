import 'package:hippolabs_native_assets/hippolabs_native_assets.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    final packageName = input.packageName;

    await HippolabsRustBuilder(
      assetName: '$packageName.dart',
      cratePath: 'rust',
      prebuilt: const HippolabsRustPrebuilt.github(),
    ).run(input: input, output: output);
  });
}
