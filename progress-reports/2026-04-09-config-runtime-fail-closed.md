## What Was Done

- Switched config discovery to fail closed for malformed or otherwise unreadable config files while still treating missing files as "keep searching / use defaults". The loader now propagates non-`FileNotFound` errors instead of silently falling back to defaults. Key changes are in `src/config.zig:107`, `src/config.zig:115`, and `src/config.zig:122`.
- Made `network.encryption` validation strict at config-load time for all binaries. Unknown values now return `error.InvalidEncryptionMode` instead of silently degrading to `preferred`. See `src/config.zig:107`, `src/config.zig:148`, and `src/config.zig:161`.
- Added explicit daemon startup gating for unsupported kernels and missing `io_uring`. The daemon now probes once at startup, prints the banner from the probed summary, and aborts with a concrete message before creating the shared event loop if the host does not meet repository policy. See `src/runtime/probe.zig:17`, `src/app.zig:26`, and `src/main.zig:35`.
- Removed dead config knobs that were present in TOML but not wired into the daemon path: `network.connect_timeout_secs`, `performance.pipeline_depth`, and `performance.ring_entries`. This keeps config surface aligned with real behavior. See `src/config.zig:41` and `src/config.zig:84`.
- Preserved `varuna --help`, `varuna-ctl --help`, and bare `varuna-ctl` usage output even when config is malformed by handling those paths before config loading. See `src/main.zig:14` and `src/ctl/main.zig:13`.
- Updated the status ledger to record the fail-closed config/startup behavior and the trimmed config surface. See `STATUS.md:28` and `STATUS.md:53`.

## What Was Learned

- The biggest operational risk in the startup path was not a crash but silent fallback. In practice that meant a malformed config could quietly reactivate default API credentials or a weaker encryption mode. Failing closed is the safer default for this daemon.
- The runtime probing code was already good enough to classify kernel support, but it was only being used for display. Reusing the same `Summary` for both banner output and policy enforcement avoids probe drift and double work.
- Removing dead config options is lower risk than trying to wire them opportunistically into unrelated hot-path code. The config contract was overstating what the daemon actually honored.
- Validation needs to live at config-load boundaries, not only at the point where one binary happens to consume a field. Otherwise secondary binaries drift into accepting config the daemon rejects.
- Semantic validation after TOML parsing still needs ordinary ownership hygiene. Rejecting a parsed config is not enough; the parsed tree has to be deinitialized on the error path too.
- Config-discovery tests need to avoid ambient machine state. The deterministic test path ended up cleaner once config search was factored into an injectable helper instead of depending on `HOME`, `XDG_CONFIG_HOME`, or `/etc`.

## Remaining Issues / Follow-Up

- This task did not yet centralize resume/DHT DB path resolution; `src/main.zig` still has duplicated path-building logic for `resume.db` and `dht.db`.
- The full `zig build test` run could not be completed in this environment because Zig failed while loading standard library/dependency cache manifests (`manifest_create Unexpected`) before reaching project compilation. That should be retried once the local Zig cache/toolchain state is healthy.
- Subsequent waves still need to address daemon tracker routing/session ownership, io shutdown safety, storage integrity, and the protocol/API issues identified in the review.
- The Wave 1.1 review loop also fixed a small semantic-validation parse-tree leak and replaced a host-dependent config-discovery test with a deterministic helper-based test in `src/config.zig`.

## Verification

- Ran `zig fmt src/config.zig src/runtime/probe.zig src/app.zig src/main.zig src/ctl/main.zig`
- Attempted `zig build test` but it failed before compiling project code due to Zig cache/toolchain loading errors.

## Key References

- `src/config.zig:107`
- `src/config.zig:122`
- `src/config.zig:148`
- `src/config.zig:161`
- `src/config.zig:190`
- `src/runtime/probe.zig:17`
- `src/runtime/probe.zig:97`
- `src/app.zig:26`
- `src/ctl/main.zig:13`
- `src/main.zig:35`
- `src/main.zig:98`
- `STATUS.md:28`
- `STATUS.md:53`
