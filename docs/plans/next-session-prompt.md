# Next Session Prompt

Copy everything below the line into a fresh Claude Code session.

---

We're building HeavyMental — a Racket-driven IDE on Tauri. Read CLAUDE.md for full architecture context.

## What's been completed

**Phases 1–4 are 100% done**, plus all enhancement rounds:

- **Phase A** (Quick Wins): Bottom panel tabs, cross-file go-to-definition, macro expansion viewer
- **Phase B** (Macro Debugger): Full rewrite with `macro-debugger/model/*` APIs — structured steps, foci highlighting, tree+stepper dual view, `syntax-parse` pattern extraction, keyboard navigation
- **Rhombus Language Support**: Monaco providers for both racket/rhombus, language-aware REPL, auto-restart on language switch, macro debugger verified with Rhombus

Phase 4 deferred items (upstream maturity): SyntaxSpec pattern visualization, Rhombus stepper, SyntaxSpec per-pattern display.

## What we're doing now: Phase 5a — Extension API

We have a **fully written implementation plan** at `docs/plans/2026-03-08-phase5a-implementation.md` and an **approved design doc** at `docs/plans/2026-03-08-phase5-extensions-design.md`. Read both.

**Phase 5a adds an extension API** that lets Racket modules contribute cells, panels, events, menus, and lifecycle hooks to the running IDE, with live reload support. Extensions use a `define-extension` macro that produces a declarative manifest. The loader handles registration/unregistration atomically with auto-namespacing. The frontend renderer is upgraded to diff layout trees by stable IDs.

### The 11 tasks (all defined in the implementation plan)

1. **Extension descriptor struct & `define-extension` macro** — core data model
2. **Extension loader** — load/unload/reload with namespacing, `cell-unregister!`
3. **Integrate dispatch into main.rkt** — event routing fallback, layout/menu merging
4. **Layout ID assignment** — `assign-layout-ids` for stable diffing
5. **Frontend diffing renderer** — ID-based reconciliation, `cell:unregister` handler
6. **Demo 1: Counter panel** — validates cells, layout, events
7. **Demo 2: Calc language** — validates menu extension, eval
8. **FS watcher Rust plumbing** — `notify` crate, `fs:watch`/`fs:unwatch` messages
9. **Demo 3: File watcher** — validates lifecycle hooks, FS access
10. **Integration test & manual verification** — end-to-end validation
11. **Update docs & memory** — session continuity

### Key design decisions (already made)

- Extension API surface: Racket first, Rhombus bindings later
- Loading model: `dynamic-require` into fresh namespaces
- Architecture: Declarative manifest via `define-extension` macro
- Layout diffing: ID-based reconciliation (Racket assigns all IDs)
- Extensions can go anywhere in the layout tree, not just bottom tabs
- Diffing preserves DOM state (Monaco editors, terminals, split ratios)

## How to execute

Use `superpowers:subagent-driven-development` to execute the implementation plan. The plan has complete code for each task — follow it closely but adapt as needed when APIs behave differently than expected. Review between tasks. Run tests after each task.

Start by reading the implementation plan: `docs/plans/2026-03-08-phase5a-implementation.md`

## Key files

| File | Why |
|------|-----|
| `CLAUDE.md` | Full architecture + conventions |
| `docs/plans/2026-03-08-phase5-extensions-design.md` | Approved design |
| `docs/plans/2026-03-08-phase5a-implementation.md` | Implementation plan (follow this) |
| `racket/heavymental-core/main.rkt` | Event dispatch, layout, state |
| `racket/heavymental-core/cell.rkt` | Reactive cell system |
| `racket/heavymental-core/protocol.rkt` | JSON-RPC messaging |
| `frontend/core/renderer.js` | Layout tree → DOM (will be rewritten for diffing) |
| `frontend/core/cells.js` | Signal-based cell registry |
| `frontend/core/bridge.js` | Tauri IPC wrapper |
| `src-tauri/src/bridge.rs` | Rust bridge (add FS watcher here) |

## Test commands

```bash
# Run all existing tests (verify no regressions)
racket test/test-bridge.rkt && racket test/test-phase2.rkt && racket test/test-phase4.rkt && racket test/test-lang-intel.rkt && racket test/test-stepper.rkt && racket test/test-macro-expander.rkt && racket test/test-pattern-extractor.rkt && racket test/test-rhombus.rkt

# Run extension tests (created during implementation)
racket test/test-extension.rkt

# Run the app
cargo tauri dev
```
