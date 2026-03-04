# Phase 2: Editor + REPL — Design Document

**Date**: 2026-03-04
**Status**: Approved

## Overview

Phase 2 turns MrRacket from a bridge demo into a minimum viable IDE. The user can open Racket files, edit them with syntax highlighting, run them, and interact with a REPL — all orchestrated by Racket through the existing bridge.

## Decisions

| Decision | Choice |
|----------|--------|
| Orchestration | Racket controls lifecycle, frontend owns internal state |
| REPL | PTY-backed xterm.js |
| Run behavior | DrRacket-style (load definitions into namespace) |
| Layout | Flexible `mr-split` primitive, composed by Racket |
| Syntax highlighting | TextMate grammar for Racket |

## New Components

### Lit Primitives

| Component | Wraps | Props |
|-----------|-------|-------|
| `mr-split` | CSS flexbox + drag handle | `direction` ("vertical"/"horizontal"), `ratio` (0.0–1.0), `min-size` (px) |
| `mr-editor` | Monaco Editor | `file-path`, `language`, `theme`, `read-only` |
| `mr-terminal` | xterm.js | `pty-id` (links to a Rust-side PTY) |
| `mr-toolbar` | Horizontal bar | Children composed from layout tree |
| `mr-statusbar` | Bottom info bar | `content` (cell reference) |

All declared by Racket in the layout tree, just like existing `mr-button` / `mr-vbox`.

## Protocol Messages

### Editor

| Direction | Type | Payload | Purpose |
|-----------|------|---------|---------|
| Racket → FE | `editor:open` | `{ path, content, language }` | Load file into Monaco |
| Racket → FE | `editor:set-content` | `{ content }` | Replace editor content |
| FE → Racket | `editor:dirty` | `{ path, dirty }` | File modified state |
| FE → Racket | `editor:save-request` | `{ path, content }` | User hit Cmd+S |

### Terminal / PTY

| Direction | Type | Payload | Purpose |
|-----------|------|---------|---------|
| FE → Rust | `pty:create` | `{ id, command, args, cols, rows }` | Spawn PTY |
| FE → Rust | `pty:input` | `{ id, data }` | User typing |
| FE → Rust | `pty:resize` | `{ id, cols, rows }` | Terminal resized |
| Rust → FE | `pty:output` | `{ id, data }` | Process output |
| Rust → FE | `pty:exit` | `{ id, code }` | Process exited |

### File I/O (Racket ↔ Rust)

| Type | Payload | Purpose |
|------|---------|---------|
| `file:open-dialog` | `{ filters }` | Native open dialog |
| `file:save-dialog` | `{ default_path }` | Native save dialog |
| `file:read` | `{ path }` | Read file contents |
| `file:write` | `{ path, content }` | Write file |

Rust handles file I/O and PTY directly — these don't pass through to the frontend. Rust responds back to Racket with results.

### Run Workflow

| Direction | Type | Payload | Purpose |
|-----------|------|---------|---------|
| FE → Racket | `event:run` | `{}` | Run button clicked |

Racket handles the run logic: save file, send `,enter <path>` to the REPL PTY.

## PTY Output Watchers (Designed, Deferred)

Racket can register FSM-based watchers on PTY output. Rust evaluates them against the stream and notifies Racket on match. This keeps the fast path (Rust → frontend) while giving Racket semantic awareness.

**Protocol:**

| Direction | Type | Payload | Purpose |
|-----------|------|---------|---------|
| Racket → Rust | `pty:add-watcher` | `{ pty_id, watcher_id, fsm }` | Register an FSM |
| Racket → Rust | `pty:remove-watcher` | `{ pty_id, watcher_id }` | Unregister |
| Rust → Racket | `pty:watcher-match` | `{ pty_id, watcher_id, matched, buffer }` | FSM triggered |

**FSM format** (JSON, defined by Racket):
```json
{
  "states": {
    "start": [
      { "match": "Error", "goto": "saw-error" },
      { "bytes": 50000, "goto": "overflow" }
    ],
    "saw-error": [
      { "match": "\\n", "goto": "done", "emit": true }
    ],
    "overflow": [
      { "emit": true, "action": "throttle" }
    ]
  },
  "initial": "start"
}
```

The `bytes` transition handles output volume — Racket can say "notify me after 50KB" without a separate mechanism. The FSM subsumes both pattern matching and volume tracking. O(1) per byte, no backtracking.

Implementation deferred to a fast-follow after basic PTY works.

## Rust Architecture

### New module: `pty.rs`
- Uses `portable-pty` crate to spawn PTY subprocesses
- Manages `HashMap<String, PtyPair>` of active PTYs
- Streams PTY output as `pty:output` events directly to frontend
- Handles `pty:input`, `pty:resize`, `pty:create`, `pty:kill` commands

### New module: `fs.rs`
- File read/write operations (responds back to Racket)
- Native open/save dialogs via Tauri's dialog API

### Changes to `bridge.rs`
- Route `pty:*` messages to `pty.rs` instead of forwarding to frontend
- Route `file:*` messages to `fs.rs` and respond to Racket
- PTY output goes directly to frontend (doesn't round-trip through Racket)

### New Tauri permissions
- `dialog:allow-open`
- `dialog:allow-save`

## Racket Architecture

### New module: `repl.rkt`
- Manages the REPL lifecycle: create PTY, load file, reset namespace
- Run workflow: save → `,enter <path>` → REPL ready
- Registers watchers (once FSM engine is built)

### New module: `editor.rkt`
- Handles `editor:save-request` — calls `file:write` via Rust
- Handles `editor:dirty` — updates status cell
- Open file workflow: `file:open-dialog` → `file:read` → `editor:open`

### Changes to `main.rkt`
- New layout tree: toolbar + mr-split + mr-editor + mr-terminal
- New cells: `current-file`, `file-dirty`, `repl-status`
- Event handlers: `run`, `open-file`, `save-file`, `new-file`
- Menu actions wired to real operations (not stubs)

### Example layout tree
```racket
(define layout
  '(mr-vbox
    (mr-toolbar
      (mr-button label: "Run" onClick: "run" variant: "primary")
      (mr-text content: cell:current-file textStyle: "mono"))
    (mr-split direction: "vertical" ratio: 0.6
      (mr-editor file-path: "" language: "racket")
      (mr-terminal pty-id: "repl"))))
```

## Vendor Dependencies

### Frontend

| Library | Purpose | Size (ESM) |
|---------|---------|-----------|
| Monaco Editor | Code editor | ~2MB |
| xterm.js + xterm-addon-fit | Terminal emulator | ~250KB |

### Rust

| Crate | Purpose |
|-------|---------|
| `portable-pty` | Cross-platform PTY |

### TextMate Grammar
- Adapt existing Racket `.tmLanguage` from VS Code extensions
- Ship as `frontend/vendor/grammars/racket.tmLanguage.json`
- Register with Monaco at startup

## Success Criteria

Phase 2 is done when:

1. Open MrRacket → see editor + terminal in a resizable split
2. File → Open → native dialog → file loads in Monaco with Racket syntax highlighting
3. Type code → editor shows "dirty" state
4. Cmd+S → file saves
5. Click Run → definitions load into REPL, terminal shows prompt
6. Type expressions in REPL → results appear
7. File → New → blank editor
