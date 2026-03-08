# Next Session Prompt

Copy everything below the line into a fresh Claude Code session.

---

We're building HeavyMental — a Racket-driven IDE on Tauri. Read CLAUDE.md for full architecture context.

## What's been completed

**Phases 1–5a are 100% done**, plus all enhancement rounds:

- **Phase A** (Quick Wins): Bottom panel tabs, cross-file go-to-definition, macro expansion viewer
- **Phase B** (Macro Debugger): Full rewrite with `macro-debugger/model/*` APIs — structured steps, foci highlighting, tree+stepper dual view, `syntax-parse` pattern extraction, keyboard navigation
- **Rhombus Language Support**: Monaco providers for both racket/rhombus, language-aware REPL, auto-restart on language switch, macro debugger verified with Rhombus
- **Phase 5a** (Extension API): `define-extension` macro, extension loader with load/unload/reload, namespaced cells/events, layout ID assignment, ID-based diffing renderer, FS watcher plumbing, 3 demo extensions (counter, calc, file-watcher), full integration tests

Phase 4 deferred items (upstream maturity): SyntaxSpec pattern visualization, Rhombus stepper, SyntaxSpec per-pattern display.

## What's next: Execute Phase 5b using subagent-driven development

**Use the `superpowers:subagent-driven-development` skill to execute the implementation plan.**

The full implementation plan is at `docs/plans/2026-03-08-phase5b-implementation.md`. Read it first — it has 13 TDD tasks with exact file paths, code, and test commands.

The design doc is at `docs/plans/2026-03-08-phase5b-design.md`.

### Phase 5b overview (DSLs & Liveness)

1. **Live reload** (Tasks 1–2): Auto-watch extension source files, debounced `reload-extension!` on change, error handling that keeps old version on syntax errors
2. **Extension manager panel** (Tasks 3–6): Rust `dialog:open-file` interception, `_extensions-list` cell, `hm-extension-manager` web component, EXTENSIONS bottom tab
3. **`heavymental/ui` embedded DSL** (Tasks 7–9): `(ui (vbox (button #:on-click handler)))` macro that builds layout hasheqs, with lambda handler auto-registration and orphan cleanup on layout rebuild
4. **`#lang heavymental/extend`** (Task 10): Reader module that desugars to `define-extension` macro
5. **`heavymental/component`** (Tasks 11–12): `define-component` macro + frontend `component:register`/`component:unregister` message handling
6. **Demo extensions + integration tests** (Task 13): Validate everything end-to-end

### Parallelization guide

These task groups can run as parallel subagents (separate worktrees):

- **Group A** (Tasks 1–2): Live reload — modifies `extension.rkt`, `main.rkt`
- **Group B** (Tasks 3, 5): Rust dialog + frontend component — modifies `bridge.rs`, creates `extension-manager.js`
- **Group C** (Tasks 7–8): UI DSL core — creates `ui.rkt`, `handler-registry.rkt`

After Groups A+B+C converge:

- **Group D** (Tasks 4, 6, 9): Wire everything together in `main.rkt`
- **Group E** (Tasks 10, 11, 12): `#lang heavymental/extend` + custom components

Final:

- **Task 13**: Demo extensions + integration tests

### Key design decisions (from brainstorming)

- **`heavymental/ui` is an embedded macro**, not a `#lang` — so it can be used inline in normal Racket code
- **Lambda handlers in `ui`**: auto-registered with `_h:N` IDs, arity-checked (0-arg or 1-arg), cleaned up by diffing old vs new layout tree on `rebuild-layout!`
- **Extension manager dialog is Racket-driven**: Racket sends `dialog:open-file` → Rust opens native picker → `dialog:result` back to Racket
- **`define-component` template accepts `ui` forms**: same layout DSL everywhere
- **Handler lifecycle**: no generations/owners — layout tree is the source of truth, orphans detected by set difference

### Racket package structure

Collection name is `"heavymental"` (from `racket/heavymental-core/info.rkt`). So:
- `heavymental/ui` → `racket/heavymental-core/ui.rkt`
- `heavymental/component` → `racket/heavymental-core/component.rkt`
- `heavymental/extend/lang/reader` → `racket/heavymental-core/extend/lang/reader.rkt`

## Test commands

```bash
# Run existing tests
racket test/test-extension.rkt && racket test/test-bridge.rkt && racket test/test-phase2.rkt && racket test/test-phase4.rkt && racket test/test-lang-intel.rkt && racket test/test-stepper.rkt && racket test/test-macro-expander.rkt && racket test/test-pattern-extractor.rkt && racket test/test-rhombus.rkt

# Run new Phase 5b tests (after implementation)
racket test/test-ui.rkt && racket test/test-component.rkt && racket test/test-extend-lang.rkt && racket test/test-phase5b-integration.rkt

# Run the app
cargo tauri dev
```
