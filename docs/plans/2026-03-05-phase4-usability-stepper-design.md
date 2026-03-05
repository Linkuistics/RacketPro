# Phase 4: End-to-End Usability + Basic Stepper

**Date**: 2026-03-05
**Status**: Approved
**Depends on**: Phase 3 (language intelligence pipeline, E2E tests, WKWebView deadlock fix)

## Goal

Make HeavyMental usable as a real IDE: open files, edit, save, run, see results, navigate errors. Then add a basic expression stepper with bindings display.

## Prior Art (What Already Works)

The Phase 2/3 infrastructure is more complete than it might seem:

- **File tree click → open file**: `file:tree-open` → Racket `file:read` → Rust reads → `file:read:result` → Racket → `editor:open` → Monaco loads. Fully wired.
- **File > Open (Cmd+O)**: Native dialog via `tauri_plugin_dialog` → same chain. Fully wired.
- **File > Save (Cmd+S)**: `editor:request-save` → frontend sends content → Racket `save-current-file` → `file:write` or `file:save-dialog`. Fully wired.
- **Run (Cmd+R)**: Sends `,enter "path"` to REPL PTY. Wired.
- **Tab bar**: Adds tabs on `editor:open`, switches on click via `tab:select`. Wired.
- **Breadcrumb play button**: Dispatches `run`. Wired.
- **Error-to-source navigation**: `editor:goto-file` → open file + jump to position. Wired.

Phase 4 is primarily **UX polish** on these existing flows plus a **new stepper feature**.

## Section 1: Dirty State + Save Flow

### Architecture: Racket Owns All State

Consistent with the core architecture, Racket owns dirty state. The frontend remains a pure rendering surface.

### Changes

**Racket (`editor.rkt`):**
- Maintain a mutable set `dirty-files` (set of path strings).
- On `editor:dirty` event with `{path}`: add path to set, update `dirty-files` cell.
- On `file:write:result` with `{path}`: remove path from set, update `dirty-files` cell.
- New cell `dirty-files` registered via `define-cell` — value is a JSON list of paths.

**Frontend (`hm-tabs`):**
- Watch the `dirty-files` cell.
- Render a `•` dot before the filename for tabs whose path appears in the dirty set.

**Save-before-close flow:**
1. Tab close button dispatches `tab:close-request {path}` to Racket (instead of closing immediately).
2. Racket checks if path is in `dirty-files`.
3. If dirty: Racket sends `dialog:confirm` message to Rust with options (Save / Don't Save / Cancel).
4. Rust shows native 3-button dialog via `tauri_plugin_dialog`.
5. Dialog result sent back to Racket as `dialog:confirm:result {id, choice}`.
6. Racket acts on choice:
   - **Save**: trigger save flow, then send `tab:close {path}` to frontend.
   - **Don't Save**: send `tab:close {path}` to frontend immediately.
   - **Cancel**: do nothing (tab stays open).
7. Frontend `hm-tabs` listens for `tab:close` and removes the tab.

**Quit with unsaved changes:**
- Window close event intercepted by Rust → sent to Racket as `lifecycle:close-request`.
- Racket checks if any files in `dirty-files` → shows dialog if needed.
- If confirmed, Racket sends `lifecycle:quit` → Rust exits.

## Section 2: File Tree ↔ Editor Sync

### Changes

**Frontend (`hm-filetree`):**
- Add an `effect()` watching the `current-file` cell.
- When it changes, set `_activeFile` to the cell value and call `requestUpdate()`.
- **Auto-reveal**: compute ancestor directory paths of the active file, add them all to `_expanded`, trigger `_loadDir()` for any not yet cached.
- **Auto-scroll**: after update, find the `.active` item in the shadow DOM and call `scrollIntoView({ block: 'nearest' })`.
- **Cache invalidation**: listen for `editor:open` events where the path is new (file just created/saved-as). Invalidate the parent directory's cache entry so it re-fetches on next expand.

No new Racket messages needed — this is purely frontend work reading existing cells.

## Section 3: Run Experience

### Save-Before-Run

**Racket (`main.rkt` / `editor.rkt`):**
- `handle-run` checks if current file is in `dirty-files`.
- If dirty: set a `pending-run` flag, trigger `editor:request-save`.
- In `handle-file-result` for `file:write:result`: if `pending-run` is set, clear it and call `run-file`.

### Clear REPL Before Run

- Before sending `,enter "path"`, send `pty:write` with `"\x0c"` (Ctrl+L form feed) to clear the terminal.
- Alternative: send `(void)\n` followed by the `,enter` to ensure a clean prompt.

### Stop/Restart Button

**Racket:**
- New cell `repl-running` (boolean). Set `#t` on run, `#f` on `pty:exit`.
- New event handler for `repl:restart`: sends `pty:kill` for "repl", then `start-repl` again.

**Frontend (`hm-breadcrumb`):**
- Watch `repl-running` cell.
- When running: change play icon to stop icon (square), click dispatches `repl:restart`.
- When not running: show play icon, click dispatches `run`.

### Run Status

- `cell:status` already updated to "Running filename.rkt" on run.
- On `pty:exit`, update status to "Finished" or "REPL exited (code N)".

## Section 4: Tab Management

### Close with Dirty Check

As described in Section 1 — `tab:close-request` → Racket → dialog if dirty → `tab:close` back to frontend.

### Middle-Click Close

**Frontend (`hm-tabs`):**
- Add `@auxclick` handler on `.tab` elements.
- If `event.button === 1`, dispatch `tab:close-request {path}`.

### Context Menu

**Frontend (`hm-tabs`):**
- Add `@contextmenu` handler on `.tab` elements.
- Show a simple custom context menu (not native) with: Close, Close Others, Close All.
- "Close Others" dispatches `tab:close-request` for all tabs except the right-clicked one.
- "Close All" dispatches `tab:close-request` for all tabs.
- Each goes through the dirty check flow in Racket.

### Tab Overflow

- When tabs exceed container width, show ← → scroll arrows at the edges.
- CSS: `overflow-x: hidden` on `.tabs-area`, JS buttons that call `scrollBy()`.
- Keep it simple — no drag reorder for v1.

### Dirty Indicator

- `hm-tabs` reads `dirty-files` cell, renders `•` before filenames that appear in the set.

## Section 5: Basic Stepper

### Approach: Racket Stepper Library

Use Racket's stepper infrastructure (from `drracket/private/stepper` or the `stepper` collection). This hooks into the evaluator to capture reduction steps — the same approach DrRacket uses.

### Racket Side (`stepper.rkt` — new file)

- `start-stepper`: takes a file path, instruments the code with the stepper, begins stepping.
- Each step produces: source location (start/end offsets), current expression text, binding environment (`[{name, value}...]`), step number, reduction rule name.
- Sends `stepper:step` message to frontend with this data.
- Responds to `stepper:forward`, `stepper:back`, `stepper:continue`, `stepper:stop` events.
- `stepper:stop` tears down the stepper sandbox.

### Cells

- `stepper-active` (boolean) — whether the stepper is running.
- `stepper-step` (integer) — current step number.
- `stepper-total` (integer) — total steps (if known, -1 if streaming).

### Frontend: Stepper UI

**Stepper toolbar** — new `hm-stepper-toolbar` component, shown when `stepper-active` is true. Contains: Step Forward, Step Back, Continue, Stop buttons.

**Expression highlighting** — On `stepper:step` message, apply a Monaco decoration (yellow background) to the source range `{startLine, startCol, endLine, endCol}`. Clear previous decoration first.

**Bindings panel** — new `hm-bindings-panel` component. Renders a simple table of variable name → value pairs. Updated on each `stepper:step` message.

### Layout Integration

When stepper is active, the bottom panel area shows the stepper toolbar + bindings panel instead of (or alongside) the terminal. This could be:
- A new tab in the bottom panel (next to TERMINAL and PROBLEMS).
- Or replace the terminal panel temporarily.

**Recommendation:** Add as a tab in the bottom panel. The panel header becomes a tab bar: TERMINAL | PROBLEMS | STEPPER. Only show STEPPER tab when `stepper-active` is true.

### Data Flow

```
User: Racket > Step Through (or Cmd+Shift+R)
  → frontend dispatches stepper:start {path}
  → Racket instruments code, creates sandbox
  → Racket sends stepper:step {location, bindings, step: 0}
  → Frontend highlights expr in Monaco, shows bindings

User: clicks Step Forward
  → frontend dispatches stepper:forward
  → Racket advances one step
  → Racket sends stepper:step {location, bindings, step: 1}
  → Frontend updates highlight + bindings

User: clicks Stop
  → frontend dispatches stepper:stop
  → Racket tears down sandbox
  → Frontend clears highlight, hides stepper panel
```

### Menu Addition

Add to the Racket menu:
```racket
(hasheq 'label "Step Through" 'shortcut "Cmd+Shift+R" 'action "step-through")
```

## Implementation Order

1. **Dirty state infrastructure** (Racket dirty-files set + cell + frontend tab indicators)
2. **Tab close with dirty check** (dialog flow through Rust)
3. **File tree ↔ editor sync** (frontend-only work)
4. **Save-before-run** (Racket pending-run state machine)
5. **REPL clear + stop/restart** (Racket + breadcrumb changes)
6. **Tab management extras** (middle-click, context menu, overflow)
7. **Stepper Racket infrastructure** (new `stepper.rkt`)
8. **Stepper UI** (toolbar, highlight decorations, bindings panel)
9. **Bottom panel tabs** (TERMINAL | PROBLEMS | STEPPER)

## Testing Strategy

- Extend existing Racket rackunit tests for dirty-state tracking logic.
- Extend Playwright E2E suite for: open file from tree, save with Cmd+S, dirty indicator visible, tab close with dirty check, run button clears + runs.
- Stepper tests: Racket unit tests for step data extraction. E2E test for step-through of a simple program.

## Demo

When Phase 4 is complete: open HeavyMental, click a `.rkt` file in the tree, edit it (see dirty dot), press Cmd+S (saved), press Cmd+R (REPL clears, file runs, output appears), click an error (jumps to source), press Cmd+Shift+R (stepper starts, step through expressions, see bindings update).
