## 0.1.2

- Answer a handler failure before the response starts with 500 and a JSON-RPC
  internal error (-32603) carrying the request id, instead of an empty 200.
  A failure after streaming started still ends the stream with the error.
- Require `dart_http_server` 0.4.0.

## 0.1.1

- Declare the pinned `dart_mcp` Git revision as a direct dependency so hosted
  consumers resolve the same MCP API as the adapter.

## 0.1.0

- Add a Dart HTTP router adapter for `dart_mcp` Streamable HTTP servers.
- Preserve request-scoped services, guards, Origin validation, JSON responses,
  SSE streaming, subscriptions, body limits, and disconnect cleanup.
