# Web Seed Range Validation

## What changed

- Added a focused `zig build test-web-seed` target for source-level web seed tests.
- Carried the expected HTTP byte range through each web seed request callback.
- Validated web seed HTTP completions before accepting bytes: exact target byte count, matching `Content-Range` for `206`, exact `Content-Length` when present, and no `200 OK` acceptance for nonzero ranges.

## What was learned

- The `HttpExecutor` already reports response headers and `target_bytes_written`, which was enough to enforce the range contract without changing the executor API.
- The prior path could accept a server that ignored the `Range` header. That would either copy the wrong slice into the run buffer or turn into hash-fail/backoff churn.
- A `200 OK` response is only defensible for a zero-start range whose object length exactly equals the requested byte count; nonzero ranges now fail immediately.

## Follow-up

- Consider moving shared HTTP header extraction into `src/io/http_parse.zig` if more HTTP response validation accumulates outside the executor.
- Add an integration-style fake web seed server that intentionally ignores `Range` to exercise the full event-loop failure path.

## Key references

- `build.zig:271` - focused `test-web-seed` target.
- `src/io/web_seed_handler.zig:55` - expected range metadata in range callback context.
- `src/io/web_seed_handler.zig:319` - range response validator.
- `src/io/web_seed_handler.zig:345` - `Content-Range` parser.
- `src/io/web_seed_handler.zig:394` - callback validation before accepting a range.
- `src/io/web_seed_handler.zig:769` - accepted exact `206 Content-Range` test.
- `src/io/web_seed_handler.zig:783` - missing/mismatched `Content-Range` tests.
- `src/io/web_seed_handler.zig:807` - short body rejection test.
- `src/io/web_seed_handler.zig:821` - nonzero-range `200 OK` rejection test.
