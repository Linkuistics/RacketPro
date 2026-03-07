# Phase B: Macro Debugger Integration + Pattern Highlighting

**Date:** 2026-03-07
**Status:** Proposed
**Depends on:** Phase A (macro expander — completed)

## Summary

Replace the hand-rolled `expand-once` expansion engine with Racket's `macro-debugger/model/*` APIs. This gives us structured expansion steps with syntax objects, source locations, foci (changed sub-expressions), and macro identity. Add a stepper view alongside the existing tree view. For user-defined `syntax-parse` macros, extract patterns from source files and color-code variable bindings against foci data.

## Motivation

The current macro panel (Phase A) uses `expand-once` in a loop, producing a tree of `{id, macro, before, after, children}` nodes. Before/after are pretty-printed strings with no source locations, no foci, and no pattern information. The macro-debugger gives us all of this for free.

Key limitations being addressed:
- No way to see *which sub-expressions changed* at each step
- No macro provenance (where is the macro defined?)
- Pattern highlighting placeholder ("not yet available")
- Namespace limitation: current expander uses `make-base-namespace`, so only `racket/base` bindings are available

## Architecture

```
                    Racket Side
              ┌─────────────────────┐
              │  macro-expander.rkt  │ (rewritten)
              │                      │
              │  macro-debugger API  │─→ trace/result → reductions
              │  pattern-extractor   │─→ read source → parse pattern
              │                      │
              │  Emits:              │
              │  • macro:steps       │ (flat step list with foci)
              │  • macro:tree        │ (derivation tree structure)
              │  • macro:pattern     │ (pattern + variable map)
              │  • macro:error       │ (unchanged)
              │  • macro:clear       │ (unchanged)
              └─────────┬───────────┘
                        │ JSON-RPC
              ┌─────────┴───────────┐
              │   hm-macro-panel    │ (rewritten)
              │                      │
              │  [Tree | Stepper]    │ ← view toggle
              │  Left: navigation   │ ← tree or step list
              │  Right: detail       │ ← before/after/pattern
              └─────────────────────┘
```

## Racket: Expansion Engine

### Dependencies

```racket
(require macro-debugger/model/trace       ; trace/result
         macro-debugger/model/reductions   ; reductions
         macro-debugger/model/steps        ; protostep, step, state structs
         macro-debugger/model/deriv)       ; mrule, base-resolves
```

Already installed with Racket 9.1 via `macro-debugger-text-lib`.

### Core function: `expand-with-debugger`

```racket
(define (expand-with-debugger source-code source-name)
  ;; 1. Read with source locations
  (define port (open-input-string source-code))
  (port-count-lines! port)
  (define stx (read-syntax source-name port))

  ;; 2. Trace expansion → derivation tree
  (define-values (result deriv) (trace/result stx))

  ;; 3. Flatten to reduction steps, filter to rewrites
  (define all-steps (reductions deriv))
  (define rw-steps (filter rewrite-step? all-steps))

  ;; 4. Serialize steps
  (define step-list (for/list ([s rw-steps] [i (in-naturals)])
                      (step->json s i)))

  ;; 5. Build tree from derivation
  (define tree (deriv->tree deriv))

  ;; 6. Emit messages
  (send-message! (make-message "macro:steps" 'steps step-list))
  (send-message! (make-message "macro:tree" 'forms tree))
  (set-cell! "current-bottom-tab" "macros"))
```

### Step JSON structure

Each step serialized as:

| Field | Source | Type |
|-------|--------|------|
| `id` | counter | `"step-0"`, `"step-1"`, ... |
| `type` | `protostep-type` | `"macro"`, `"tag-app"`, `"tag-datum"`, ... |
| `typeLabel` | `step-type->string` | `"Macro transformation"`, ... |
| `macro` | `base-resolves` on derivation | string or `null` |
| `macroModule` | `identifier-binding` | string or `null` |
| `before` | `step-term1` → `syntax->datum` → pretty-format | string |
| `after` | `step-term2` → `syntax->datum` → pretty-format | string |
| `beforeLoc` | `syntax-position`/`syntax-span` on `step-term1` | `{offset, span}` or `null` |
| `foci` | `state-foci` → serialize positions | `[{offset, span}, ...]` |
| `fociAfter` | `state-foci` on after-state | `[{offset, span}, ...]` |
| `seq` | `state-seq` | integer or `null` |

### Tree JSON structure

Built from the derivation's `mrule` hierarchy:

| Field | Type |
|-------|------|
| `id` | `"node-N"` |
| `macro` | string or `null` |
| `stepIds` | `["step-3", "step-4"]` — corresponding flat step IDs |
| `label` | first 50 chars of before text |
| `children` | recursive list of tree nodes |

### Namespace improvement

Use `(make-base-namespace)` enriched with the file's `#lang` imports, or use `trace-module` when expanding a file path. This fixes the current limitation where only `racket/base` bindings are available.

## Racket: Pattern Extraction

New module: `pattern-extractor.rkt`

### Eligibility

A macro step is eligible for pattern extraction when:
1. Step type is `'macro`
2. `identifier-binding` returns a module path (not `#f`)
3. The module is user-defined or a library (not `racket/base` or other core)
4. The source file is readable on disk

### Extraction process

1. Get module path from `identifier-binding` on the resolved macro identifier
2. Resolve to filesystem path via `resolved-module-path-name`
3. Read the source file
4. Search for the macro's definition form:
   - `define-syntax-parse-rule` → pattern is the S-expression after the name
   - `define-simple-macro` → pattern is the S-expression after the name
   - `define-syntax` + `syntax-parse` → extract pattern clauses
   - `syntax-case` → skip (not supported)
5. Extract pattern text and identify pattern variable names
6. Match pattern variables against foci data heuristically

### Pattern message

```json
{
  "type": "macro:pattern",
  "stepId": "step-3",
  "pattern": "(_ condition:expr then:expr else:expr)",
  "variables": [
    {"name": "condition", "color": "#4CAF50", "beforeSpan": {"offset": 4, "span": 8}},
    {"name": "then",      "color": "#2196F3", "beforeSpan": {"offset": 13, "span": 5}},
    {"name": "else",      "color": "#FF9800", "beforeSpan": {"offset": 19, "span": 6}}
  ],
  "source": "my-macros.rkt:15"
}
```

### Limitations

- Only supports `define-syntax-parse-rule`, `define-simple-macro`, and `define-syntax` with `syntax-parse`
- Built-in Racket macros (`cond`, `let`, `match`, etc.) show foci highlighting only, no pattern
- Multi-clause macros: all patterns shown, best-effort match to determine which clause fired
- Source file must be accessible on disk
- Pattern variable to sub-expression mapping is heuristic

## Frontend: Macro Panel

### Layout

Toolbar with view toggle:

```
┌────────────────────────────────────────────────────────────┐
│ [🌲 Tree] [▶ Stepper]  │ Step 3/12 [◀][▶] │ [Filter] [×] │
├────────────────────────────────────────────────────────────┤
```

Step counter and prev/next shown in both views. Filter dropdown in stepper view only.

### Tree view (default)

```
┌──────────────────────┬──────────────────────────────────┐
│ Expansion Tree       │  Detail                          │
│                      │                                  │
│ ▼ cond →             │  Macro: cond (racket/base)       │
│   ▼ if →             │                                  │
│     #%app            │  Before:                         │
│     ▼ cond →         │  ┌────────────────────────────┐  │
│       ...            │  │ (cond [#t 1] [else 2])     │  │ ← foci highlighted
│                      │  └────────────────────────────┘  │
│                      │                                  │
│                      │  After:                          │
│                      │  ┌────────────────────────────┐  │
│                      │  │ (if #t 1 (cond [else 2]))  │  │ ← foci highlighted
│                      │  └────────────────────────────┘  │
│                      │                                  │
│                      │  Pattern: (when available)       │
│                      │  ┌────────────────────────────┐  │
│                      │  │ (_ test:expr then:body ...) │  │ ← color-coded
│                      │  │ from: my-macros.rkt:15      │  │
│                      │  └────────────────────────────┘  │
└──────────────────────┴──────────────────────────────────┘
```

### Stepper view

```
┌──────────────────────┬──────────────────────────────────┐
│ Steps                │  (same detail pane)               │
│                      │                                  │
│ 1. macro: cond       │                                  │
│ 2. tag: #%app        │                                  │
│ 3. macro: if      ●  │                                  │
│ 4. rename: let       │                                  │
│ ...                  │                                  │
└──────────────────────┴──────────────────────────────────┘
```

Filter options: All steps / Macro steps only / Hide renames+tags

### Foci highlighting

In the before/after code blocks, sub-expressions identified by `foci` are wrapped in colored `<span>` elements:
- **Green** — sub-expression preserved from input (likely a pattern variable binding)
- **Orange** — sub-expression newly generated by the template
- **Red** — sub-expression consumed/removed (present in before, absent in after)

When pattern data is available, colors are overridden to match the pattern variable's assigned color.

### Keyboard navigation

- Left/Right arrows: prev/next step
- Up/Down arrows: tree navigation (in tree view) or step selection (in stepper view)
- Tab: toggle between tree and stepper views
- Escape: close/clear

## Testing

### Racket unit tests (rackunit)

| Test | Description |
|------|-------------|
| `trace/result` produces valid derivation | Basic smoke test |
| `reductions` returns rewrite steps for `cond` | Step list is non-empty, contains `rewrite-step?` items |
| Each step has syntax source locations | `step-term1` has `syntax-position` and `syntax-span` |
| `state-foci` returns foci for macro steps | Non-empty list of syntax objects |
| `base-resolves` returns macro identifier | For `mrule` nodes in the derivation |
| Step serialization produces valid JSON | `step->json` output has all required fields |
| Tree built from derivation is correct | Parent-child relationships match expansion structure |
| Pattern extraction finds `define-syntax-parse-rule` | Given a test file with a syntax-parse macro |
| Pattern extraction returns `null` for built-in macros | `cond`, `let`, etc. |
| Error handling: malformed source | Produces `macro:error` message |
| Error handling: empty file | No crash |

### Frontend manual testing (debug harness)

- Tree view renders, nodes expand/collapse
- Stepper view renders, prev/next navigate correctly
- View toggle switches between tree and stepper
- Foci highlighting appears in before/after blocks
- Pattern section appears for eligible macros
- Pattern section hidden for built-in macros
- Filter dropdown works in stepper view
- Keyboard navigation works

## Migration

The current `macro-expander.rkt` is rewritten (not patched). Changes:

1. **Replace** `expand-once` loop with `trace/result` + `reductions`
2. **Fix** namespace: use proper module namespace instead of `make-base-namespace`
3. **Add** `pattern-extractor.rkt` module
4. **Rewrite** `hm-macro-panel` with tree/stepper toggle and foci highlighting
5. **Change** `macro:tree` message payload (nodes now reference step IDs)
6. **Add** `macro:steps` and `macro:pattern` message types
7. **Keep** `macro:expand`, `macro:stop`, `macro:clear` event names unchanged
8. **Update** tests to cover new data structures

## Non-goals

- Pattern extraction for `syntax-case` macros
- Pattern extraction for built-in Racket macros
- SyntaxSpec nonterminal introspection (no API exists)
- Real-time expansion (expansion runs on trigger, not on keystroke)
- Undo/redo of expansion steps
