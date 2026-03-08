# Next Session Prompt

Copy everything below the line into a fresh Claude Code session.

---

We're building HeavyMental — a Racket-driven IDE on Tauri. Read CLAUDE.md for full architecture context.

## What's been completed

**Phases 1–5b are 100% done**, plus all enhancement rounds. Phase 6 has been **designed and planned** but not yet implemented.

## What's next: Execute Phase 6 using subagent-driven development

The design doc is at `docs/plans/2026-03-08-phase6-polish-distribution-design.md`.
The implementation plan is at `docs/plans/2026-03-08-phase6-implementation.md`.

**Use the `superpowers:subagent-driven-development` skill to execute the implementation plan.**

### Phase 6 scope (decided)

1. **Theming** — Racket-driven themes (hasheqs of CSS variable values). Light + dark built-in. Extensions can register themes. `theme:apply` message sets CSS custom properties + Monaco theme.
2. **Settings** — Two-tier: global JSON in `~/Library/Application Support/` (Rust manages) + per-project `.heavymental/settings.rkt` (Racket reads). Deep-merge with defaults.
3. **Multi-file projects** — Directory-is-project with `info.rkt` auto-detection. Find-in-project via Rust `ignore`+`regex` crates. SEARCH tab in bottom panel. Cmd+Shift+F.
4. **Keyboard shortcuts** — Keybinding registry in Racket (separate from menus). Frontend keydown handler. Visual keybinding editor in settings panel with click-to-record. Vim mode toggle (monaco-vim).
5. **Settings UI** — Opens as editor tab via Cmd+,. Sections: Appearance, Editor, Keybindings. `hm-settings-panel` Lit component.
6. **Packaging** — DMG bundle config in tauri.conf.json, app icon, Racket-not-found detection dialog. No code signing.

Tray icon was **dropped** from scope.

### Parallel track structure (3 tracks + integration + packaging)

The plan is organized into 3 independent parallel tracks that subagents can work on concurrently:

| Track | Tasks | Scope |
|-------|-------|-------|
| **Track 1** | Tasks 1–4 | Settings persistence (Rust + Racket) + Theming (Racket + Frontend) |
| **Track 2** | Tasks 5–7 | Project detection (Racket) + File search (Rust) + Search panel (Frontend) |
| **Track 3** | Tasks 8–10 | Keybinding registry (Racket) + Frontend keydown handler + Vim mode |
| **Integration** | Task 11 | Settings UI panel (depends on all 3 tracks) |
| **Packaging** | Task 12 | Tauri bundle config + Racket-not-found detection |
| **Verification** | Task 13 | Run all tests, verify build, test app |

**Important:** Tracks 1, 2, and 3 have zero dependencies between them. Dispatch them as parallel subagents. Tasks 11–13 must run sequentially after all tracks complete.

### Key architectural patterns (for subagents)

- **New Racket module**: `#lang racket/base`, `(require "protocol.rkt" "cell.rkt")`, explicit `(provide ...)`, test with rackunit
- **New message type**: Racket sends via `(send-message! (make-message "type" 'key value))`, Rust intercepts in `handle_intercepted_message` match arm in `bridge.rs`, or frontend handles via `onMessage('type', callback)` in `bridge.js`
- **New cell**: `(define-cell name initial-value)` in `main.rkt`, auto-syncs to frontend signal
- **New web component**: Lit `LitElement` subclass in `frontend/core/primitives/`, import in `main.js`, register with `customElements.define('hm-name', ClassName)`
- **CSS theming**: All components use `var(--property-name, fallback)`. Properties defined in `frontend/style/reset.css`
- **Testing**: Racket rackunit only. No JS tests. Test files in `test/`, require modules via relative paths like `"../racket/heavymental-core/module.rkt"`

### Test commands

```bash
# Run ALL tests (Phases 1–6)
racket test/test-settings.rkt && racket test/test-theme.rkt && racket test/test-project.rkt && racket test/test-keybindings.rkt && racket test/test-extension.rkt && racket test/test-bridge.rkt && racket test/test-phase2.rkt && racket test/test-phase4.rkt && racket test/test-lang-intel.rkt && racket test/test-stepper.rkt && racket test/test-macro-expander.rkt && racket test/test-pattern-extractor.rkt && racket test/test-rhombus.rkt && racket test/test-ui.rkt && racket test/test-component.rkt && racket test/test-extend-lang.rkt && racket test/test-phase5b-integration.rkt

# Verify Rust builds
cargo build -p heavy-mental

# Run the app
cargo tauri dev
```
