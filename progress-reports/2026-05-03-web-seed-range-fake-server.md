# Web Seed Range Fake Server Integration

## What changed

- Added an in-process fake web seed server/executor that the web seed handler submits real range jobs to. The fake server records and validates the exact `Range` header before returning a response.
- Added handler-flow tests for a successful `206 Partial Content` range and ignored-Range `200 OK` responses, including the slot failure path that releases the claimed piece and backs off the seed.
- Tightened range response validation so `200 OK` is rejected for web seed downloads even when the requested span starts at byte 0. The handler always sends `Range`, so `200 OK` means the origin ignored the request contract.

## What was learned

- The callback can be exercised without sockets by matching the `HttpExecutor.Job` surface and invoking `on_complete` synchronously.
- The generic web seed completion path references the hashing/inline-write fallback at compile time, so the fake event loop needs small stubs for those surfaces even when the tests stop before disk I/O.

## Remaining issues or follow-up

- If more HTTP handler-flow tests are added, consider extracting the fake executor/server harness into a shared test helper instead of keeping it local to `web_seed_handler.zig`.
- The shell E2E server still provides coarse request stats; these source tests now cover exact Range observation deterministically.

## Key code references

- `src/io/web_seed_handler.zig:321` - range response validator.
- `src/io/web_seed_handler.zig:338` - `200 OK` rejection for web seed Range requests.
- `src/io/web_seed_handler.zig:778` - fake web seed server that records and validates `Range`.
- `src/io/web_seed_handler.zig:1088` - positive fake-server range request through the handler flow.
- `src/io/web_seed_handler.zig:1141` - ignored-Range response fails the slot end-to-end.
- `src/io/web_seed_handler.zig:1198` - ignored-Range `200 OK` is rejected even for zero-start requests.
