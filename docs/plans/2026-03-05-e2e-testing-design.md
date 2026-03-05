# End-to-End Testing Design

**Goal:** Comprehensive, scripted regression tests that verify the full application works — from Racket protocol through Rust bridge to rendered UI.

## Two-Tier Strategy

### Tier 1: Racket Subprocess Protocol Tests (`test/test-e2e.rkt`)

Spawn `main.rkt` as a real subprocess, pipe JSON through stdin/stdout, verify the full message protocol. This tests Racket's boot sequence, dispatch loop, cell system, file operations, language intelligence, and REPL — the same way Rust talks to it.

**Why:** Racket is the brain. If its protocol works, the app works. Fast (~2s/test), no Tauri needed.

**Test cases:**
1. Boot sequence — startup messages arrive in correct order
2. File open — `file:read:result` → `editor:open` with correct language
3. Dirty tracking — `editor:dirty` → title updates with `*`
4. New file — `new-file` → `editor:open` with `#lang racket` template
5. Language intelligence — `document:opened` → all `intel:*` messages arrive
6. Document changes — `document:changed` → re-analysis with updated intel
7. Completions — `intel:completion-request` → `intel:completion-response`
8. Error diagnostics — source with syntax error → error diagnostics
9. #lang detection — `#lang rhombus` → language cell updates
10. Editor goto — `editor:goto` → echo back
11. REPL commands — `run` event → `pty:write` with `,enter` command
12. Ping/pong — protocol health check

### Tier 2: Playwright UI Tests (`test/e2e/`)

Launch `cargo tauri dev`, use Playwright to interact with the real app through the rendered UI. Tests the full stack including Rust bridge, DOM rendering, Monaco, terminal.

**Test cases:**
1. App launches — window appears, layout renders
2. Layout structure — toolbar, sidebar, editor, terminal, status bar all present
3. Editor loads — Monaco editor initializes, shows content
4. File operations — open file via toolbar/menu, editor shows content
5. Error panel — diagnostics appear for files with errors
6. Terminal — xterm.js renders, REPL prompt appears
7. Status bar — shows language, cursor position reactively

## Architecture

```
test/
├── test-bridge.rkt         # Unit: protocol, cells
├── test-phase2.rkt         # Unit: editor, REPL
├── test-lang-intel.rkt     # Unit: check-syntax
├── test-e2e.rkt            # E2E: Racket subprocess protocol
└── e2e/
    ├── package.json        # Playwright dependency
    ├── playwright.config.js
    └── app.spec.js         # Full-stack UI tests
```
