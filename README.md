# Dart HTTP

Protocol-neutral HTTP packages for Dart applications and frameworks maintained by Hippolabs.

This repository owns reusable HTTP wire models and helpers. It deliberately has no dependency on
Dart Edge or Hippobase; those frameworks can depend on packages from this workspace instead.

## Packages

| Package | Description |
| --- | --- |
| [`sse_helpers`](packages/sse_helpers) | Bounded, incremental Server-Sent Events encoding and decoding. |

## Development

```sh
dart pub get
dart run melos run ci
```
