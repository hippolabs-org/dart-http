# dart_http_native_client

Asynchronous Rust HTTP transport for `dart_http_core`. A persistent Tokio and
reqwest runtime owns connection pooling, request cancellation, and response
streaming. Native Exchange bodies transfer ownership directly to Rust; network
response chunks remain native-owned until consumed or explicitly copied.

```dart
final transport = await NativeHttpClientTransport.open();
final response = await transport.sendStream(request);
await for (final chunk in response.bodyStream) {
  // Copied compatibility stream.
}
transport.close();
```

Use `sendNative` when the consumer can keep the response body in Native
Exchange instead of materializing chunks in the Dart heap.
