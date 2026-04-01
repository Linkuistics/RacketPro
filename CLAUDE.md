# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

RacketPro (internally "HeavyMental") — a Racket-driven IDE built on Tauri. Racket is the brain: it declares UI, manages state, handles events, controls menus. Rust/Tauri is a thin bridge that spawns Racket, routes JSON-RPC over stdin/stdout, and provides OS access. The frontend is a rendering surface using Lit Web Components + @preact/signals-core. No framework, no build step.

## Commands

```bash
# Run in development mode (builds Rust, launches Tauri window, spawns Racket)
cargo tauri dev

# Build release
cargo tauri build

# Run all Racket tests
racket test/test-bridge.rkt
racket test/test-phase2.rkt
racket test/test-lang-intel.rkt
racket test/test-stepper.rkt
racket test/test-macro-expander.rkt
racket test/test-pattern-extractor.rkt
racket test/test-extension.rkt
racket test/test-extend-lang.rkt
racket test/test-component.rkt
racket test/test-ui.rkt
racket test/test-keybindings.rkt
racket test/test-settings.rkt
racket test/test-theme.rkt
racket test/test-project.rkt
racket test/test-rhombus.rkt
racket test/test-phase4.rkt
racket test/test-phase5b-integration.rkt

# Run a single test file
racket test/test-bridge.rkt

# Install Racket dependencies
cd racket/heavymental-core && raco pkg install --auto

# Verify a Racket import works
racket -e '(require drracket/check-syntax) (displayln "ok")'
```

There is no frontend build step — Tauri serves `frontend/` as static files. Vendor libraries (Lit, Monaco, xterm.js, signals) are pre-bundled ESM in `frontend/vendor/`.

## Architecture

### Three-layer message-passing design

```
Frontend (Lit Web Components + signals)
    ↕ Tauri IPC (invoke / events)
Rust Bridge (spawns Racket, routes JSON, manages PTY/FS/menus)
    ↕ stdin/stdout JSON-RPC
Racket Core (state, layout, events, language intelligence)
```

**Racket → Frontend flow:** Racket calls `send-message!` which writes JSON to stdout → Rust reads it, emits Tauri event `racket:<type>` → Frontend's `bridge.js` dispatches to `onMessage()` handlers.

**Frontend → Racket flow:** Frontend calls `dispatch(name, payload)` → Tauri invoke `send_to_racket` → Rust writes JSON to Racket's stdin → Racket's `start-message-loop` dispatches to `handle-event`.

**Rust intercepts** certain messages instead of forwarding: `menu:set` → native menus, `pty:create/write/resize` → PTY management, `cell:register/update` → also forwarded to frontend.

### Reactive cells

Racket declares cells (`cell:register`), updates them (`cell:update`). Frontend mirrors them as `@preact/signals-core` signals. Layout props can reference cells with `"cell:<name>"` syntax, resolved by `renderer.js`.

### Layout system

Racket sends a layout tree via `layout:set`. The renderer maps `type` to `hm-<type>` custom elements. Layout primitives: `hm-vbox`, `hm-hbox`, `hm-split`, `hm-toolbar`, `hm-statusbar`, `hm-tabs`, `hm-filetree`, `hm-panel-header`, `hm-editor`, `hm-terminal`, `hm-error-panel`.

### Language intelligence pipeline

Racket runs `drracket/check-syntax` on source code → extracts arrows, hovers, colors, diagnostics, definitions → sends `intel:*` messages to frontend. Frontend's `lang-intel.js` caches data per-URI and feeds Monaco providers (hover, definition, completion). `arrows.js` renders SVG Bezier curves for binding arrows.

## Key Files

| File | Role |
|------|------|
| `src-tauri/src/lib.rs` | Tauri setup, command handlers, PATH augmentation for macOS bundles |
| `src-tauri/src/bridge.rs` | Rust bridge: spawns Racket, JSON-RPC routing, native menus, file I/O, dialogs |
| `src-tauri/src/pty.rs` | PTY process management (portable-pty) with generation tracking |
| `src-tauri/src/search.rs` | Project-wide text search (ignore + regex crates) |
| `src-tauri/src/settings.rs` | Settings persistence to ~/Library/Application Support/ |
| `racket/heavymental-core/main.rkt` | Racket entry: cells, layout, menu, event/menu dispatch, startup sequence |
| `racket/heavymental-core/protocol.rkt` | JSON message primitives: `send-message!`, `read-message`, `make-message` |
| `racket/heavymental-core/cell.rkt` | Reactive cell system: `define-cell`, `cell-set!`, `cell-ref` |
| `racket/heavymental-core/editor.rkt` | File ops, `#lang` detection, dirty tracking, pending actions |
| `racket/heavymental-core/repl.rkt` | REPL lifecycle: start, run-file, restart, language switching |
| `racket/heavymental-core/lang-intel.rkt` | Check-syntax integration: `analyze-source`, `build-trace%`, intel cache |
| `racket/heavymental-core/stepper.rkt` | Interactive stepper using `stepper/private/model` |
| `racket/heavymental-core/macro-expander.rkt` | Macro expansion tracing using `macro-debugger` |
| `racket/heavymental-core/extension.rkt` | Extension system: load/unload/reload, namespacing, live-watch |
| `racket/heavymental-core/ui.rkt` | Declarative UI DSL macro with auto-handler registration |
| `racket/heavymental-core/theme.rkt` | Theme system: Light/Dark built-in, `register-theme!` API |
| `racket/heavymental-core/keybindings.rkt` | Keybinding registry with defaults and customization |
| `frontend/core/bridge.js` | Tauri IPC wrapper: `onMessage()`, `dispatch()`, `request()` |
| `frontend/core/renderer.js` | Layout tree to DOM with ID-based diffing |
| `frontend/core/lang-intel.js` | Intel cache + Monaco providers (diagnostics, hover, definition, completion) |
| `frontend/core/arrows.js` | SVG Bezier binding arrows overlay on Monaco |
| `frontend/core/primitives/editor.js` | Monaco editor wrapper, language registration, document sync |

## Conventions

- **Racket message types** use colon-separated namespaces: `cell:update`, `intel:diagnostics`, `editor:open`, `menu:action`, `pty:output`
- **Web Components** are prefixed `hm-` and live in `frontend/core/primitives/`
- **All components** extend `LitElement` directly (layout primitives) or `HmElement` (for deferred init avoiding WKWebView IPC deadlock)
- **No build step** — all frontend code is native ES modules with an import map in `index.html`
- **Tests** are Racket-only (rackunit). No JS tests. Test files require modules via relative paths like `"../racket/heavymental-core/protocol.rkt"`
- **Racket provides** are explicit — every exported function must be in the `provide` list
- **Title separator** is em-dash (`\u2014`), not hyphen: `"HeavyMental — filename.rkt"`
- **Monaco column convention**: Racket uses 0-based columns, Monaco uses 1-based. Always `+1` when converting Racket→Monaco.

## Debug Harness

In debug builds, `/tmp/heavymental-debug/` provides:
- `console.log` → captured to `console.log` file
- DOM snapshots → `dom.html`
- JS eval: write to `eval-input.js`, result appears in `eval-output.txt`
- CrabNebula devtools for Rust tracing (auto-starts)

## Environment

- Rust 1.93.1, Node.js 23.10.0 (pinned in `.tool-versions`)
- Racket with `drracket-tool-lib` package installed
- macOS primary target (WKWebView)
