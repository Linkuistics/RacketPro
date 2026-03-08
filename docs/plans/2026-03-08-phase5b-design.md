# Phase 5b: DSLs & Liveness

**Date**: 2026-03-08
**Status**: Approved
**Depends on**: Phase 5a (Extension API) — complete

## Vision

Phase 5b adds liveness (live reload + extension manager) and three embedded DSLs that make extension authoring natural. The execution order is liveness first, DSLs second — real-world extension authoring experience informs DSL design.

## 1. Live Reload

The FS watcher plumbing (notify crate in Rust, `watch-directory!` in Racket) already exists. Live reload adds an auto-reload layer:

- `load-extension!` auto-watches the source file path
- `unload-extension!` auto-unwatches
- `fs:change` on a watched extension file triggers debounced `reload-extension!` (300ms)
- The ID-based diffing renderer preserves editor/terminal state during rebuild

### New pieces

- `watch-extensions!` / `unwatch-extension!` in `extension.rkt` — track which files are watched
- Hook into `load-extension!` to auto-watch, `unload-extension!` to auto-unwatch
- Debounce logic in the `fs:change` handler (Racket side, simple timer)
- Status feedback: `_reload-status` cell updated on reload success/failure

### Error handling

- Syntax errors during reload: catch exn, keep old version loaded, surface error via `_reload-status` cell
- File deleted: unload the extension gracefully

## 2. Extension Manager Panel

A built-in bottom tab (alongside TERMINAL/PROBLEMS/STEPPER/MACROS) for managing extensions from the IDE.

### Layout

```
┌─ EXTENSIONS ─────────────────────────────────────┐
│ ● Counter          [Reload] [Unload]             │
│ ● Calc Language    [Reload] [Unload]             │
│ ● File Watcher     [Reload] [Unload]             │
│                                                   │
│ [Load Extension...]                               │
└───────────────────────────────────────────────────┘
```

### Implementation

- Core feature in `main.rkt`, not an extension
- New cell `_extensions-list`: JSON array of `{id, name, path, status}`, updated on load/unload
- New primitive: `hm-extension-manager` web component renders the list from the cell
- Status indicators: green = active, red = error (failed reload)

### File dialog (Racket-driven)

- Racket sends `dialog:open-file` message with filter `*.rkt`
- Rust intercepts, opens native file picker via Tauri's `dialog::FileDialogBuilder`
- Result sent back to Racket as `dialog:result` with selected path
- Racket calls `load-extension!` with the path

### New message types

| Message | Direction | Purpose |
|---------|-----------|---------|
| `dialog:open-file` | Racket -> Rust | Request native file picker |
| `dialog:result` | Rust -> Racket | File picker result (path or null) |

## 3. `heavymental/ui` — Embedded Layout DSL

A macro for building layout trees inline in normal Racket code.

### Usage

```racket
(require heavymental/ui)

(define my-layout
  (ui
    (vbox
      (text #:content "cell:count")
      (hbox
        (button #:label "+1" #:on-click (lambda () (cell-update! 'count add1)))
        (button #:label "Reset" #:on-click "reset"))
      (split #:direction "horizontal" #:ratio 0.7
        (editor)
        (terminal)))))
```

### What `ui` does

- Transforms `(type #:key val ... children ...)` into `(hasheq 'type "hm-type" 'props (hasheq ...) 'children (list ...))`
- Auto-prefixes `hm-` to element types: `vbox` -> `"hm-vbox"`, `editor` -> `"hm-editor"`
- Composable via unquote: `(ui (vbox ,header (editor)))` splices pre-built layout nodes

### Lambda event handlers

Handler values can be strings (named events) or lambdas (auto-registered):

```racket
(button #:on-click "increment")                           ; named event
(button #:on-click (lambda () (cell-update! 'count add1))) ; auto-registered
(button #:on-click (lambda (msg) (handle msg)))            ; with payload
```

**Auto-registration:**
1. `ui` macro detects non-string handler values
2. Generates unique ID with `_h:` prefix (e.g. `"_h:0"`, `"_h:1"`)
3. Registers the lambda in a handler table on the Racket side
4. Substitutes the string ID into the serialized layout

**Arity handling:**
- `(procedure-arity-includes? fn 1)` → call `(fn msg)`
- Otherwise → call `(fn)`
- Neither 0 nor 1 args → error

**Handler cleanup:**
- On layout send, walk old tree to collect `_h:*` IDs, walk new tree to collect `_h:*` IDs
- Delete handlers in old set but not new set
- No generations, no owners — the layout tree is the source of truth

## 4. `#lang heavymental/extend` — Extension DSL

A reader module that desugars to `define-extension`. Less boilerplate for extension authors.

### Surface syntax

```racket
#lang heavymental/extend

name: "Counter"

cell count = 0

panel counter "Counter" bottom
  (hm-vbox
    (hm-text #:content "cell:count")
    (hm-button #:label "+1" #:on-click "increment"))

event increment
  (cell-update! 'count add1)

menu "Extensions" "Reset Counter" "Cmd+Shift+R" reset-counter

on-activate
  (displayln "Counter loaded")

on-deactivate
  (displayln "Counter unloaded")
```

### Implementation

- Reader module at `heavymental/extend/lang/reader.rkt`
- Parses declarations into keyword arguments for `define-extension`
- Can use `ui` macro inside panel layouts
- Can use lambda handlers in events
- Errors surface as readable syntax errors with correct line numbers

## 5. `#lang heavymental/component` — Custom Web Components

Define new `hm-*` elements from Racket, injectable into the frontend at runtime.

### Usage

```racket
(require heavymental/component)
(require heavymental/ui)

(define-component hm-sparkline
  #:tag "hm-sparkline"
  #:properties ([data "cell:spark-data"]
                [color "#4CAF50"]
                [height 32])
  #:template (ui
               (canvas #:width 200 #:height 'height))
  #:style "
    :host { display: inline-block; }
    canvas { width: 100%; }
  "
  #:script "
    updated(props) {
      const ctx = this.shadowRoot.querySelector('canvas').getContext('2d');
      // draw sparkline from props.data
    }
  ")
```

### Runtime flow

1. Racket sends `component:register` message with tag, template, style, script
2. Frontend dynamically calls `customElements.define()` with a LitElement subclass
3. Component is usable in any layout tree: `(ui (sparkline #:data "cell:spark-data"))`
4. On extension unload: `component:unregister` removes the element definition

### Template

- Accepts `ui` form (preferred) — same layout DSL used everywhere
- Falls back to raw HTML string
- Property references (e.g. `'height`) resolve to component props

### JS interface

- `updated(props)` — called on prop changes
- `connected()` — called on mount
- `disconnected()` — called on unmount

### `#:style` stays as CSS string

CSS doesn't benefit from S-expression wrapping.

### New message types

| Message | Direction | Purpose |
|---------|-----------|---------|
| `component:register` | Racket -> Frontend | Define a new custom element |
| `component:unregister` | Racket -> Frontend | Remove a custom element definition |

## Execution Order

1. **Live reload** (item 1) — leverages existing FS watcher, small surface area
2. **Extension manager** (item 2) — validates extension API under real use
3. **`heavymental/ui` macro** (item 3) — foundation DSL, needed by items 4 and 5
4. **`#lang heavymental/extend`** (item 4) — reader that desugars to `define-extension`, uses `ui`
5. **`#lang heavymental/component`** (item 5) — custom components, uses `ui` for templates

## Key Files

| File | Role |
|------|------|
| `racket/heavymental-core/extension.rkt` | Live reload hooks, handler table |
| `racket/heavymental-core/main.rkt` | Extension manager layout, dialog handling |
| `racket/heavymental-core/ui.rkt` | `ui` macro, handler auto-registration |
| `racket/heavymental-core/component.rkt` | `define-component` macro |
| `racket/heavymental-extend/lang/reader.rkt` | `#lang heavymental/extend` reader |
| `frontend/core/primitives/extension-manager.js` | `hm-extension-manager` web component |
| `frontend/core/component-registry.js` | Dynamic custom element registration |
| `src-tauri/src/bridge.rs` | `dialog:open-file` interception |
