# ctl HTTP facade lifetime fix

## What changed and why

- Fixed `varuna-ctl`'s synchronous HTTP facade so the `HttpExecutor` no longer stores a pointer to an IO backend that lived on `Client.init`'s stack.
- The facade now creates a short-lived epoll POSIX IO backend and shared `HttpExecutor` inside each request, drives it until the callback completes, and tears it down before returning.
- This keeps the synchronous wrapper under `src/ctl/` while preserving the shared HTTP request/response path.

## What was learned

- `varuna-ctl version` against a live daemon crashed with a null function pointer because `Client.init` returned by value after giving `HttpExecutor.create` `&io` for a stack local.
- A gdb stack trace confirmed the bad pointer was used during `EpollPosixIO.registerFd` from the HTTP executor connect path.

## Validation

- `nix run nixpkgs#zig_0_15 -- build test-ctl --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix run nixpkgs#zig_0_15 -- build --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `varuna-ctl version` against the live debug daemon returned `"2.9.3"`.

## Key references

- `src/ctl/api_client.zig:28` `Client` no longer owns a backend pointer.
- `src/ctl/api_client.zig:103` each request owns the stable IO/executor pair.
- `src/ctl/main.zig:501` callers use the non-fallible `Client.init`.
