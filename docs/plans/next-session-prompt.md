# Next Session Prompt

Copy everything below the line into a fresh Claude Code session.

---

We're building HeavyMental — a Racket-driven IDE on Tauri. Read CLAUDE.md for full architecture context.

## What's been completed

**Phases 1–5b are 100% done**, plus all enhancement rounds:

- **Phase A** (Quick Wins): Bottom panel tabs, cross-file go-to-definition, macro expansion viewer
- **Phase B** (Macro Debugger): Full rewrite with `macro-debugger/model/*` APIs — structured steps, foci highlighting, tree+stepper dual view, `syntax-parse` pattern extraction, keyboard navigation
- **Rhombus Language Support**: Monaco providers for both racket/rhombus, language-aware REPL, auto-restart on language switch, macro debugger verified with Rhombus
- **Phase 5a** (Extension API): `define-extension` macro, extension loader with load/unload/reload, namespaced cells/events, layout ID assignment, ID-based diffing renderer, FS watcher plumbing, 3 demo extensions (counter, calc, file-watcher), full integration tests
- **Phase 5b** (DSLs & Liveness): `heavymental/ui` embedded macro DSL, `#lang heavymental/extend` reader, `heavymental/component` for custom web components, live reload with `dynamic-rerequire`, extension manager panel (`hm-extension-manager`), lambda handler auto-registration with orphan cleanup, Rust `dialog:open-file` for native file picker, 3 demo extensions (counter-ui, hello-component, timer-extend), frontend component registry

Phase 4 deferred items (upstream maturity): SyntaxSpec pattern visualization, Rhombus stepper, SyntaxSpec per-pattern display.

## What's next: Brainstorm and execute Phase 6 using subagent-driven development

Phase 6 from the design doc is: **Polish + Distribution** — Native menus, tray, shortcuts (Racket-driven). Theming. Multi-file projects. Settings. Packaging for macOS.

**Use the `superpowers:brainstorming` skill first** to design Phase 6. Then use `superpowers:writing-plans` to create the implementation plan, and `superpowers:subagent-driven-development` to execute it.

### Phase 6 scope (from design doc, needs brainstorming)

The design doc is intentionally terse. Brainstorming should flesh out:

1. **Theming** — Racket-driven theme system? CSS custom properties? Dark/light mode? Extension-provided themes?
2. **Settings** — Where stored (JSON? Racket config?)? What's configurable? UI for settings panel?
3. **Multi-file projects** — Project concept? Workspace file? Racket `info.rkt` integration? Find-in-project?
4. **Keyboard shortcuts** — Already have Racket-driven menus with shortcuts. What's missing? Customizable keybindings?
5. **Tray** — macOS menu bar integration? What actions?
6. **Packaging for macOS** — `cargo tauri build` already works. Code signing? DMG? Auto-update?

### What already exists (avoid reimplementing)

- Native menus are **already Racket-driven** (Phase 1) — `menu:set` messages, extension menus merge
- Keyboard shortcuts already work via menu accelerators
- `cargo tauri build` already produces a macOS app bundle
- Extension system is complete (load/unload/reload, manager panel, live reload)

### Key files for Phase 6

| Area | Files |
|------|-------|
| Menus | `racket/heavymental-core/main.rkt` (menu declarations), `src-tauri/src/bridge.rs` (native menu creation) |
| Layout | `racket/heavymental-core/main.rkt` (layout tree), `frontend/core/renderer.js` (DOM rendering) |
| Cells/State | `racket/heavymental-core/cell.rkt`, `frontend/core/bridge.js` (signal mirroring) |
| Extensions | `racket/heavymental-core/extension.rkt`, `racket/heavymental-core/ui.rkt`, `racket/heavymental-core/component.rkt` |
| Editor | `racket/heavymental-core/editor.rkt`, `frontend/core/primitives/editor.js` |
| Styling | `frontend/core/primitives/*.js` (component styles), `frontend/styles.css` (global) |
| Tauri config | `src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml` |

## Test commands

```bash
# Run ALL tests (Phases 1–5b)
racket test/test-extension.rkt && racket test/test-bridge.rkt && racket test/test-phase2.rkt && racket test/test-phase4.rkt && racket test/test-lang-intel.rkt && racket test/test-stepper.rkt && racket test/test-macro-expander.rkt && racket test/test-pattern-extractor.rkt && racket test/test-rhombus.rkt && racket test/test-ui.rkt && racket test/test-component.rkt && racket test/test-extend-lang.rkt && racket test/test-phase5b-integration.rkt

# Run the app
cargo tauri dev
```
