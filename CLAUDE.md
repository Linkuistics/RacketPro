# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

HeavyMental — a Racket-driven IDE (DrRacket replacement) built on Tauri. Racket is the brain: it declares UI, manages state, handles events, controls menus. Rust/Tauri is a thin bridge that spawns Racket, routes JSON-RPC over stdin/stdout, and provides OS access. The frontend is a rendering surface using Lit Web Components + @preact/signals-core. No framework, no build step.

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
| `src-tauri/src/bridge.rs` | Rust bridge: spawns Racket, JSON-RPC routing, native menus |
| `src-tauri/src/pty.rs` | PTY process management (portable-pty) |
| `racket/heavymental-core/main.rkt` | Racket entry: layout declaration, event dispatcher |
| `racket/heavymental-core/protocol.rkt` | JSON message primitives: `send-message!`, `read-message`, `make-message` |
| `racket/heavymental-core/lang-intel.rkt` | Check-syntax integration: `analyze-source`, `build-trace%`, offset conversion |
| `racket/heavymental-core/editor.rkt` | File ops, `#lang` detection, language detection |
| `frontend/core/bridge.js` | Tauri IPC wrapper: `onMessage()`, `dispatch()`, `request()` |
| `frontend/core/renderer.js` | Layout tree → DOM: creates `hm-*` elements from Racket layout |
| `frontend/core/lang-intel.js` | Intel cache + Monaco providers (diagnostics, hover, definition, completion) |
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
