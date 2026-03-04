# Phase 3: Language Intelligence — Design Document

**Date:** 2026-03-05
**Status:** Draft
**Prerequisite:** Phase 2 (IDE layout, editor, terminal, file tree) — complete

## Goal

Make HeavyMental language-aware. After Phase 3, editing Racket code in HeavyMental
should feel like a proper IDE: semantic coloring, binding arrows, error squiggles,
hover docs, go-to-definition, completions, and clickable error traces.

**Demo target:** Open a Racket file → see semantic coloring (blue = local, green =
imported, red = mutated) → hover shows type/docs → Ctrl+click goes to definition →
Check Syntax arrows show binding structure → errors appear as squiggly underlines +
error panel → run code → REPL error is clickable back to source → switch to
`#lang rhombus` file → proper syntax highlighting.

## Architecture

### Design Principle: Racket-Driven, Push-Based

Consistent with HeavyMental's core philosophy: **Racket is the brain, the frontend
is a thin rendering surface.** All language intelligence is computed by Racket and
pushed to the frontend. The frontend caches data locally and feeds it to Monaco
providers — no request/response round-trips except for position-sensitive completions.

### System Diagram

```
┌──────────────────────────────────────────────────────────┐
│  Racket (single process)                                 │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ lang-intel.rkt                                     │  │
│  │                                                    │  │
│  │  Uses drracket/check-syntax directly:              │  │
│  │  - make-traversal + build-trace% class             │  │
│  │  - Collects: arrows, hovers, colors, definitions,  │  │
│  │    references, diagnostics, unused requires        │  │
│  │  - Stores results in interval maps                 │  │
│  │  - Runs analysis on background place               │  │
│  │  - Pushes all intel:* messages to frontend         │  │
│  │  - Serves completion requests from cached trace    │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  JSON-RPC bridge protocol (existing)                     │
├──────────────────────────────────────────────────────────┤
│  Rust (unchanged, language-agnostic)                     │
│  Routes messages, no language-specific logic added.      │
├──────────────────────────────────────────────────────────┤
│  Frontend (thin rendering)                               │
│                                                          │
│  ┌──────────────┐  ┌───────────┐  ┌──────────────────┐  │
│  │ lang-intel.js│  │ arrows.js │  │ hm-error-panel   │  │
│  │ ~100 lines   │  │ ~80 lines │  │ Lit component    │  │
│  │ Caches intel │  │ SVG over  │  │                  │  │
│  │ data, feeds  │  │ Monaco    │  │                  │  │
│  │ Monaco provs │  │           │  │                  │  │
│  └──────────────┘  └───────────┘  └──────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

### Why Not racket-langserver?

racket-langserver is a thin LSP wrapper around `drracket/check-syntax`. Since
HeavyMental already has its own protocol and Racket orchestrates everything, using
racket-langserver would mean: (a) a second Racket process, (b) an unnecessary LSP
translation layer, (c) no access to raw check-syntax arrows. Building directly on
`drracket/check-syntax` gives us everything racket-langserver provides, plus raw
arrow data for the canvas overlay, in a single process.

## Protocol

### Push Messages (Racket → Frontend)

All intelligence data is pushed after analysis completes. The frontend caches it.

| Message | Payload | Frontend Action |
|---|---|---|
| `intel:diagnostics` | `{uri, items: [{range, severity, message, source}]}` | `monaco.editor.setModelMarkers()` |
| `intel:arrows` | `{uri, arrows: [{from, to, kind, hover}]}` | SVG overlay + decorations |
| `intel:hovers` | `{uri, hovers: [{range, contents}]}` | Cache for hover provider |
| `intel:completions` | `{uri, items: [{label, kind, detail, doc}]}` | Cache for completion provider |
| `intel:definitions` | `{uri, defs: [{range, target_uri, target_range}]}` | Cache for definition provider |
| `intel:references` | `{uri, refs: [{range, locations}]}` | Cache for reference provider |
| `intel:colors` | `{uri, colors: [{range, style}]}` | Decorations (semantic tokens) |
| `intel:clear` | `{uri}` | Clear all cached intelligence data |

### Document Sync Messages (Frontend → Racket)

| Message | Payload | Purpose |
|---|---|---|
| `document:opened` | `{uri, text, languageId}` | Trigger initial analysis |
| `document:changed` | `{uri, changes: [{range, text}]}` | Trigger debounced re-analysis |
| `document:closed` | `{uri}` | Cleanup cached data |

### Request/Response (for position-sensitive completions)

| Direction | Message | Payload |
|---|---|---|
| FE → Racket | `intel:completion-request` | `{uri, position: {line, col}, prefix, id}` |
| Racket → FE | `intel:completion-response` | `{id, items: [{label, kind, detail, insertText, doc}]}` |

### Range Format

All ranges use `{startLine, startCol, endLine, endCol}` (1-based lines, 0-based
columns) to match Monaco's convention. Racket converts from character offsets
using port position tracking.

## Racket-Side Design

### `lang-intel.rkt`

**Dependencies:** `drracket/check-syntax`, `data/interval-map`, `racket/place`

**Core type: `build-trace%`**

Extends `annotations-mixin` from drracket/check-syntax. Overrides:

- `syncheck:add-arrow/name-dup/pxpy` → collect binding arrows
- `syncheck:add-mouse-over-status` → collect hover text
- `syncheck:color-range` → collect semantic coloring
- `syncheck:add-definition-target/phase-level+space` → collect definition sites
- `syncheck:add-jump-to-definition/phase-level+space` → collect jump targets
- `syncheck:add-unused-require` → diagnostic: unused require
- Error handler → collect expansion errors as diagnostics

Results stored in interval maps for O(log n) position lookups.

**Analysis lifecycle:**

1. `document:opened` → start initial `analyze!` on background place
2. `document:changed` → debounce 500ms → re-`analyze!`
3. Analysis completes → convert trace to `intel:*` messages → push to frontend
4. `document:closed` → drop cached trace

**Background place:**

check-syntax expansion can take seconds for large files. Analysis runs on a Racket
place (parallel thread with its own namespace). The main thread continues handling
events. When the place finishes, it sends results back via place-channel.

If a new edit arrives while analysis is running, the in-progress analysis is
abandoned and a new one starts (debounced).

**Completions:**

Pre-computed from the check-syntax trace:
- All identifiers visible at module level (from `syncheck:add-definition-target`)
- All imported identifiers
- `namespace-mapped-symbols` for the current namespace
- Pushed as `intel:completions` after analysis

Position-sensitive filtering handled via `intel:completion-request`: Racket checks
which identifiers are in scope at the given position using the interval map.

### Integration with `main.rkt`

New message dispatches added to the event handler:
- `document:opened` → `(lang-intel:handle-opened uri text lang)`
- `document:changed` → `(lang-intel:handle-changed uri changes)`
- `document:closed` → `(lang-intel:handle-closed uri)`
- `intel:completion-request` → `(lang-intel:handle-completion-request ...)`

### Integration with `editor.rkt`

- On file open: emit `document:opened` to lang-intel (in addition to `editor:open` to frontend)
- On file save: re-emit `document:changed` to trigger fresh analysis
- #lang detection: read first line, extract `#lang` identifier, include in `document:opened`

## Frontend Design

### `lang-intel.js` (~100 lines)

**Responsibilities:**
- Listen for `intel:*` messages from bridge
- Cache data per-URI in Maps
- Register Monaco providers that read from cache:
  - `registerHoverProvider` — lookup hover from cached `intel:hovers`
  - `registerCompletionItemProvider` — send `intel:completion-request`, await response
  - `registerDefinitionProvider` — lookup from cached `intel:definitions`
  - `registerReferenceProvider` — lookup from cached `intel:references`
- Apply diagnostics via `monaco.editor.setModelMarkers()`
- Apply decorations via `editor.createDecorationsCollection()` from `intel:colors`
- On `intel:clear`, remove all cached data and clear markers/decorations

### `arrows.js` (~80 lines)

**SVG overlay for Check Syntax binding arrows.**

- Creates an SVG element positioned absolutely over the Monaco editor
- `pointerEvents: 'none'` so clicks pass through to editor
- On `intel:arrows` message, stores arrow data
- Renders visible arrows as SVG `<path>` Bezier curves
- Uses `editor.getScrolledVisiblePosition()` for text-to-pixel coordinate mapping
- Viewport culling: only draw arrows whose endpoints are visible
- Re-renders on `onDidScrollChange` and `onDidLayoutChange`
- Arrow colors by kind:
  - `binding` → blue (#4488ff)
  - `tail` → purple (#aa44ff), dashed
  - `require` → green (#44aa44)
- Interaction: hover over decorated identifier → highlight connected arrows

### `hm-error-panel` (Lit Web Component)

**Error list panel, similar to VS Code's "Problems" panel.**

```
┌──────────────────────────────────────────────────┐
│ PROBLEMS (3)                              ▼  ✕   │
├──────────────────────────────────────────────────┤
│ ⊘ unbound identifier: foo       main.rkt:5:3    │
│ ⊘ arity mismatch: expected 2    main.rkt:12:1   │
│ ⚠ unused require: racket/list   main.rkt:2:0    │
└──────────────────────────────────────────────────┘
```

- Populated from `intel:diagnostics` data
- Click a row → editor jumps to that location
- Severity icons: error (red), warning (yellow), info (blue)
- Panel lives in the layout below the terminal, toggled by button or keyboard shortcut
- Racket controls visibility via cell

### REPL Error-to-Source Mapping

**In `hm-terminal`:**
- Regex matcher detects Racket error output patterns: `path:line:col: message`
- Renders matched locations as clickable spans (styled links) in terminal output
- Click → sends `editor:goto {uri, line, col}` to Racket
- Racket handles by opening the file (if not already open) and emitting `editor:open`
  with cursor position

## #lang Detection

**Racket-side (`editor.rkt`):**
- On file open, read the first line of content
- Match `#lang <identifier>` pattern
- Map to language ID: `racket`, `rhombus`, `typed/racket`, `scribble`, etc.
- Include `languageId` in `document:opened` message
- Frontend uses this to set Monaco language mode

**Impact on analysis:**
- check-syntax works for any `#lang` — it uses `read-syntax` + `expand`, which
  dispatches to the `#lang` reader automatically
- Different `#lang`s may produce different quality of check-syntax data (Rhombus
  may have fewer syntax properties initially)

## Rhombus Monarch Tokenizer

**File:** `frontend/core/rhombus-language.js`

Registers a `rhombus` language with Monaco. Handles:
- Keywords: `fun`, `def`, `let`, `class`, `interface`, `match`, `cond`, `if`, `when`, `unless`, `import`, `export`, `open`, `module`, `block`, `begin`, `for`, `each`
- Operators: `+`, `-`, `*`, `/`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `&&`, `||`, `!`, `~`, `.`, `::`, `:~`, `|>`
- Delimiters: `(`, `)`, `[`, `]`, `{`, `}`, `:`, `|`, `,`, `;`
- Strings: `"..."` with `${}` interpolation
- Comments: `//` line, `/* */` block, `@` at-expressions
- Numbers: decimal, hex (`0x`), binary (`0b`)
- Boolean: `#true`, `#false`

This is a static tokenizer. check-syntax semantic tokens (from `intel:colors`) will
override with more accurate coloring where available.

## File Changes Summary

### New Files
| File | Purpose | Size Estimate |
|---|---|---|
| `racket/heavymental-core/lang-intel.rkt` | check-syntax integration, trace, analysis | ~300 lines |
| `frontend/core/lang-intel.js` | Monaco providers, intel cache | ~100 lines |
| `frontend/core/arrows.js` | SVG arrow overlay | ~80 lines |
| `frontend/core/primitives/error-panel.js` | `hm-error-panel` component | ~80 lines |
| `frontend/core/rhombus-language.js` | Monarch tokenizer for Rhombus | ~150 lines |

### Modified Files
| File | Changes |
|---|---|
| `racket/heavymental-core/main.rkt` | Dispatch `document:*` and `intel:*` messages to lang-intel |
| `racket/heavymental-core/editor.rkt` | #lang detection, emit `document:opened/changed/closed` |
| `frontend/core/primitives/editor.js` | Mount SVG overlay, emit document sync events, apply decorations |
| `frontend/core/primitives/terminal.js` | Error pattern detection, clickable source links |
| `frontend/core/bridge.js` | Request/response correlation (id-based) for completions |
| `frontend/core/renderer.js` | Register `hm-error-panel` primitive |
| `frontend/core/main.js` | Import lang-intel.js, arrows.js, rhombus-language.js |

### Rust Changes
**None.** Rust remains language-agnostic. All new messages route through the
existing bridge.

## Build Order (Bottom-Up Pipeline)

1. **Protocol + document sync** — `document:opened/changed/closed` messages, #lang detection
2. **Diagnostics pipeline** — check-syntax errors → `intel:diagnostics` → squiggly underlines
3. **Semantic coloring** — `intel:colors` → Monaco decorations
4. **Hover** — `intel:hovers` → Monaco hover provider
5. **Go-to-definition + references** — `intel:definitions` + `intel:references` → Monaco providers
6. **Completions** — `intel:completions` push + `intel:completion-request/response`
7. **Check Syntax arrows** — `intel:arrows` → SVG overlay with interactions
8. **Error panel** — `hm-error-panel` component, layout integration
9. **REPL error mapping** — terminal error detection, clickable links
10. **Rhombus tokenizer** — `rhombus-language.js`, language switching

## Testing Strategy

- **Racket unit tests:** test `build-trace%` with known Racket source, verify arrow/hover/diagnostic data
- **Integration tests:** Racket sends intel messages → verify frontend receives and caches correctly
- **Manual testing:** open sample files, verify hover, click-to-definition, arrow rendering
- **Error cases:** syntax errors mid-edit (analysis should still return partial results), #lang not found

## Open Questions

1. **Incremental analysis:** check-syntax does full expansion. For large files, this may be slow on every keystroke even with debouncing. Future optimization: cache expanded syntax and only re-expand changed forms. Deferred to Phase 4+.

2. **Cross-file navigation:** go-to-definition for imported identifiers needs to open other files. check-syntax provides `syncheck:add-jump-to-definition` with file paths. The frontend can request Racket to open the target file. Not complex but needs testing with various import patterns.

3. **Rhombus check-syntax quality:** Rhombus may not attach all the syntax properties that `#lang racket` does (e.g., `'disappeared-use`, `'sub-range-binders`). Arrow coverage for Rhombus may be incomplete initially. This is acceptable — it will improve as Rhombus matures.
