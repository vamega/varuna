## What Was Done And Why

Updated repository documentation so it reflects the current codebase instead of blending current operating rules with older planning language.

- Updated `AGENTS.md` to name the current subsystems under `src/`, emphasize build-driven focused test steps, and clarify that the `io_uring` section is a current daemon operating rule.
- Updated `docs/future-features.md` to state that it is a deferred/follow-up document rather than a source-of-truth list of missing features.
- Updated `docs/dht-bep52-plan.md` to state that DHT and most BEP 52 runtime support already exist, and that the document should be read as planning/follow-up context.
- Updated `STATUS.md` with a short note describing the documentation correction.

The goal was to prevent future agents from inferring that implemented subsystems such as DHT, uTP, UDP tracker support, PEX, magnet handling, and encryption are still only aspirational.

## What Was Learned

- Older planning docs become actively misleading once the implementation outgrows them unless they explicitly declare their scope.
- In this repo, the main risk was not incorrect low-level policy. The `io_uring` rule was largely accurate already. The real problem was context drift around that rule.
- `AGENTS.md` needs to function as current operating guidance, not just repository-shape advice.

## Remaining Issues Or Follow-Up Work

- `docs/future-features.md` still contains historical DONE sections for already-landed milestones. That is acceptable for now, but a future cleanup could split completed milestones from actual deferred work.
- If more subsystem-specific operating constraints emerge, they should be added to `AGENTS.md` as current-state instructions, not buried only in progress reports.

## Code References

- `AGENTS.md:3`
- `AGENTS.md:58`
- `docs/future-features.md:1`
- `docs/dht-bep52-plan.md:1`
- `STATUS.md:227`
