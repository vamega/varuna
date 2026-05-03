# RPC Parser Compatibility

## What changed

- Added a focused `zig build test-rpc-parser` target for source-level RPC parser compatibility coverage.
- Made cookie SID extraction accept semicolon-delimited cookie pairs with or without a space after `;`.
- Trimmed optional spaces/tabs around HTTP header values before parsing `Content-Length`, `Content-Type`, and `Connection`.
- Routed API handlers against the path component before `?`, while preserving the original request target for endpoints that parse query parameters.

## What was learned

- The existing parser already handled case-insensitive header names and HTTP/1.1 keep-alive correctly.
- Route dispatch was the fragile layer for exact qBittorrent endpoints: `/api/v2/app/defaultSavePath?rid=...` reached the handler but missed exact string matching and returned 404.
- Cookie parsing was stricter than common browser/client behavior because it expected `"; "` rather than a raw semicolon separator.

## Follow-up

- The form/query helper still decodes matching values in-place. It should eventually move to a parsed parameter table or allocator-backed decoded values so repeated lookups cannot be affected by decoded delimiter bytes inside earlier values.

## Key references

- `build.zig:260` - focused `test-rpc-parser` target.
- `src/rpc/auth.zig:138` - semicolon-based cookie pair parsing.
- `src/rpc/server.zig:656` - header extraction trims optional whitespace.
- `src/rpc/handlers.zig:60` - route path computed without query string.
- `src/rpc/handlers.zig:2499` - `pathWithoutQuery` helper.
- `src/rpc/auth.zig:232` - no-space cookie regression test.
- `src/rpc/server.zig:863` - optional whitespace `Content-Length` regression test.
- `tests/api_endpoints_test.zig:62` - exact route with query-string regression test.
