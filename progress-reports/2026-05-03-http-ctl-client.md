# HTTP ctl client facade

## What changed and why
- Added shared HTTP request construction and response parsing helpers so callers do not hand-build method/body/header requests (`src/io/http_parse.zig:16`, `src/io/http_parse.zig:38`, `src/io/http_parse.zig:178`).
- Extended the async `HttpExecutor` job model to carry method, body, content type, and cookie metadata while keeping completion callback behavior unchanged (`src/io/http_executor.zig:98`, `src/io/http_executor.zig:940`).
- Moved the synchronous control-plane facade into `src/ctl/` and made it drive the shared async `HttpExecutor` over the epoll POSIX backend, leaving daemon/core code with the callback executor only (`src/ctl/api_client.zig:21`, `src/ctl/api_client.zig:70`).
- Rewired `varuna-ctl` login/get/post helpers through the ctl facade, added global `--format human|json` parsing groundwork, and added `api get` / `api post` passthrough commands (`src/ctl/main.zig:40`, `src/ctl/main.zig:465`, `src/ctl/main.zig:492`).
- Added a focused `zig build test-ctl` target for ctl parsing/facade tests (`build.zig:250`).

## Remaining issues or follow-up
- Human formatting still prints raw response bodies; the new `--format` parser establishes the switch point for later command-specific formatting.
- `api post` accepts a single body argument. A later pass could add `--content-type` and body-from-file support for larger or JSON payloads.
- The ctl facade still supports IPv4 daemon bind addresses, matching the previous `varuna-ctl` behavior.
