# Quick Wins + Macro Expansion Viewer Design

**Date:** 2026-03-07
**Scope:** Bottom panel tabs, cross-file go-to-definition, file:read sequencing fix, macro expansion tree, SyntaxSpec pattern highlighting

## 1. Bottom Panel Tabs

### Current State

The bottom panel is a flat vbox stacking all sections vertically: `panel-header("TERMINAL")` -> `terminal` -> `panel-header("PROBLEMS")` -> `error-panel` -> `stepper-toolbar` -> `bindings-panel`. Sections toggle visibility via cells. No tab switching.

### Design

VS Code-style tab bar at top of bottom panel. Four fixed tabs: **TERMINAL | PROBLEMS | STEPPER | MACROS**. Clicking a tab shows that panel, hides others.

#### Layout Tree Change

```
vbox (bottom panel)
+-- hm-bottom-tabs (fixed tab bar)
+-- hm-tab-content (container, shows one child at a time)
    +-- terminal (visible when tab = "terminal")
    +-- error-panel (visible when tab = "problems")
    +-- vbox[stepper-toolbar + bindings-panel] (visible when tab = "stepper")
    +-- macro-panel (visible when tab = "macros")
```

#### New Component: `hm-bottom-tabs`

Purpose-built tab bar (not reusing `hm-tabs` which has editor-specific close/dirty logic).

- **Fixed tabs** declared in Racket layout: `[{id: "terminal", label: "TERMINAL"}, ...]`
- **Cell:** `current-bottom-tab` (string, default `"terminal"`)
- **Badge:** PROBLEMS tab shows diagnostic count from `problems-count` cell
- **Styling:** 28px height, uppercase labels, bottom border on active tab
- **Click:** Updates `current-bottom-tab` cell via dispatch

#### New Component: `hm-tab-content`

Container that shows only the child matching the active tab.

- Each child has `data-tab-id` attribute
- Subscribes to `current-bottom-tab` cell
- Sets `display: none` on non-active children

#### Auto-switching

- `intel:diagnostics` with errors -> switch to PROBLEMS
- `stepper:step` -> switch to STEPPER
- `macro:step` -> switch to MACROS

## 2. Cross-File Go-to-Definition

### Current State

`lang-intel.js:208` has a TODO: when `j.targetUri` exists (cross-file reference), returns `null`. The definition provider works for same-file arrows but not cross-file jumps.

`main.rkt:200` has a TODO: sends `file:read` then immediately `editor:goto` without waiting for the file to load.

### Design

#### Pending-goto Queue

Add `_pending-goto` variable in `editor.rkt`:

1. Receive `editor:goto-definition` event with `{path, name}` or `editor:goto-file` with `{path, line, col}`
2. Set `_pending-goto` to the request data
3. Send `file:read {path}` (or skip if file already open)
4. On `file:read:result`: process normally, check `_pending-goto`
5. If pending-goto matches path:
   - For `goto-definition`: run `analyze-source` on target file, find definition of `name`, send `editor:goto`
   - For `goto-file`: send `editor:goto` with stored line/col
6. Clear `_pending-goto`

#### Frontend Changes

In `lang-intel.js` definition provider:
- When `j.targetUri` exists: dispatch `editor:goto-definition {path: j.targetUri, name: j.name}`
- Return `null` (we handle navigation ourselves, not Monaco)

#### Flow: Cross-file go-to-definition

```
Cmd-click symbol with targetUri
  -> lang-intel.js dispatches editor:goto-definition {path, name}
  -> Racket sets _pending-goto, sends file:read
  -> Rust reads file, returns file:read:result
  -> Racket opens file (editor:open), runs analyze-source on target
  -> Racket finds definition position, sends editor:goto {line, col}
  -> Monaco jumps to definition in newly opened tab
```

#### Flow: REPL error goto (fixes main.rkt:200 TODO)

```
Click error location in REPL output
  -> Racket receives editor:goto-file {path, line, col}
  -> Racket sets _pending-goto {path, line, col}, sends file:read
  -> file:read:result arrives, editor:open sent
  -> _pending-goto matches: send editor:goto {line, col}
```

## 3. Macro Expansion Tree

### Approach

Use recursive `expand-once` to build an expansion tree. Each node represents a macro application with before/after syntax. The tree is sent as a single `macro:tree` message to the frontend.

### Racket Side: `macro-expander.rkt`

New module providing:

- `start-macro-expander : path -> void` — reads source, recursively expands, builds tree, sends to frontend
- `stop-macro-expander : -> void` — clears state, resets cells

#### Expansion Algorithm

```
expand-and-trace(stx) -> tree-node
  1. If stx is not a syntax pair -> return leaf {form: (syntax->datum stx)}
  2. result = expand-once(stx)
  3. If result eq? stx -> fully expanded, return leaf
  4. Identify macro name from syntax head
  5. Create node: {id, macro-name, before, after}
  6. Recursively expand-and-trace sub-expressions of result
  7. Attach sub-results as children
```

#### Cells

- `macro-active` (bool) — controls MACROS tab state

#### Messages

- `macro:tree {forms: [{id, macro, before, after, children: [...]}]}` — full expansion tree
- `macro:error {error: string}` — expansion failed
- `macro:clear` — reset

### Frontend Side: `hm-macro-panel`

New component in `frontend/core/primitives/macro-panel.js`.

#### Layout

```
+-----------------------------------------+
| [Expand] [Collapse All]  file.rkt       |
+--------------------+--------------------+
| Expansion Tree     | Detail View        |
|                    |                    |
| > (cond ...)       | Before:            |
|   > cond -> if     |   [Monaco editor]  |
|   > if -> ...      |                    |
| > (define-struct)  | After:             |
|   > define-struct  |   [Monaco editor]  |
|                    |                    |
|                    | Macro: cond        |
|                    | From: racket/base  |
+--------------------+--------------------+
| Pattern Match (SyntaxSpec - Phase B)    |
+-----------------------------------------+
```

- **Left pane:** Collapsible tree. Each node shows macro name + transformation summary
- **Right pane:** Read-only Monaco editors showing before/after forms with Racket syntax highlighting
- **Info bar:** Macro name and source module

#### Interaction

- Click tree node -> show before/after in detail pane
- Expand/collapse tree nodes
- "Expand" button triggers `dispatch('macro:expand')`

### Triggering

- **Toolbar button:** "Expand Macros" next to Step Through button in breadcrumb toolbar
- **Menu:** Run -> "Expand Macros" (Cmd+Shift+E)
- Auto-switches bottom panel to MACROS tab

## 4. SyntaxSpec Pattern Match Highlighting

### Phased Approach

**Phase A (this work):** Build expansion tree infrastructure. Pattern highlighting UI area is present but shows "Pattern info not available" for non-SyntaxSpec macros.

**Phase B (follow-up):** Add pattern extraction and highlighting for SyntaxSpec macros.

### Phase B Design (for reference)

When a tree node's macro was defined with `define-syntax-parse-rule` or `define-simple-macro`:

1. **Racket:** Read the macro's source file, parse the definition form, extract pattern
2. **Racket:** Match input syntax against pattern to identify variable bindings: `{var -> input-subexpression}`
3. **Frontend:** In the "Before" Monaco editor, highlight each matched sub-expression with a distinct color
4. **Frontend:** Show the pattern in a third pane, color-code pattern variables to match input highlights

Example: pattern `(my-macro x:expr y:expr)` matching `(my-macro (+ 1 2) "hello")`:
- `(+ 1 2)` highlighted in blue (= `x`)
- `"hello"` highlighted in green (= `y`)

### Limitations

- Only supports macros defined with SyntaxSpec surface forms (`define-syntax-parse-rule`, `define-simple-macro`)
- Built-in Racket macros won't show pattern info
- General `syntax-parse` support is a future extension

## Files to Create/Modify

### New Files

| File | Purpose |
|------|---------|
| `frontend/core/primitives/bottom-tabs.js` | Bottom panel tab bar component |
| `frontend/core/primitives/tab-content.js` | Tab content container (shows active tab's panel) |
| `frontend/core/primitives/macro-panel.js` | Macro expansion tree + detail view |
| `racket/heavymental-core/macro-expander.rkt` | Recursive expand-once tree builder |

### Modified Files

| File | Changes |
|------|---------|
| `racket/heavymental-core/main.rkt` | New layout tree with bottom-tabs, new cells, new event handlers |
| `racket/heavymental-core/editor.rkt` | Pending-goto queue, sequencing fix |
| `frontend/core/lang-intel.js` | Cross-file go-to-definition dispatch |
| `frontend/core/renderer.js` | Register new component types (bottom-tabs, tab-content, macro-panel) |
| `src-tauri/src/bridge.rs` | Route macro:* messages (if needed) |

### Test Files

| File | Purpose |
|------|---------|
| `test/test-macro-expander.rkt` | Unit tests for expansion tree building |
