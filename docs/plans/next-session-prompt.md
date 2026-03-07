# Next Session Prompt

Copy everything below the line into a fresh Claude Code session.

---

We're building HeavyMental — a Racket-driven IDE on Tauri. Read CLAUDE.md for full architecture context.

## What's been completed

**Phases 1–4 are 100% done**, plus all enhancement rounds:

- **Phase A** (Quick Wins): Bottom panel tabs, cross-file go-to-definition, macro expansion viewer
- **Phase B** (Macro Debugger): Full rewrite with `macro-debugger/model/*` APIs — structured steps, foci highlighting, tree+stepper dual view, `syntax-parse` pattern extraction, keyboard navigation
- **Rhombus Language Support**: Monaco providers for both racket/rhombus, language-aware REPL, auto-restart on language switch, macro debugger verified with Rhombus
- **Phase 5a** (Extension API): `define-extension` macro, extension loader with load/unload/reload, namespaced cells/events, layout ID assignment, ID-based diffing renderer, FS watcher plumbing, 3 demo extensions (counter, calc, file-watcher), full integration tests

Phase 4 deferred items (upstream maturity): SyntaxSpec pattern visualization, Rhombus stepper, SyntaxSpec per-pattern display.

## What's next: Phase 5b — DSLs & Liveness

Phase 5b focuses on:
- `#lang heavymental/ui` — DSL for declaring UI layouts in Racket
- `#lang heavymental/component` — DSL for defining custom Web Components from Racket
- `#lang heavymental/extend` — DSL for writing extensions with less boilerplate
- Live reload: watch extension files and auto-reload on save
- Extension manager panel (list/load/unload extensions from the IDE)

### Design considerations

- Core libraries in stable Racket, surface DSLs can use Rhombus/SyntaxSpec
- Extension file watcher Rust plumbing is already in place (notify crate)
- Layout diffing renderer preserves DOM state during reloads
- Extensions currently bottom-tab-only; generalize to arbitrary layout positions

### Key files for Phase 5b

| File | Role |
|------|------|
| `CLAUDE.md` | Full architecture + conventions |
| `docs/plans/2026-03-08-phase5-extensions-design.md` | Phase 5 design (covers 5a+5b) |
| `racket/heavymental-core/extension.rkt` | Extension API: descriptor, loader, FS watcher |
| `racket/heavymental-core/main.rkt` | Event dispatch, layout merging, rebuild-layout! |
| `frontend/core/renderer.js` | ID-based diffing renderer |
| `frontend/core/cells.js` | Cell registry with unregister support |
| `src-tauri/src/bridge.rs` | Rust bridge with FS watcher (notify crate) |
| `extensions/counter.rkt` | Demo: counter panel |
| `extensions/calc-lang.rkt` | Demo: calc language with menu |
| `extensions/file-watcher.rkt` | Demo: FS watcher with lifecycle hooks |

## Test commands

```bash
# Run all tests
racket test/test-extension.rkt && racket test/test-bridge.rkt && racket test/test-phase2.rkt && racket test/test-phase4.rkt && racket test/test-lang-intel.rkt && racket test/test-stepper.rkt && racket test/test-macro-expander.rkt && racket test/test-pattern-extractor.rkt && racket test/test-rhombus.rkt

# Run the app
cargo tauri dev
```
