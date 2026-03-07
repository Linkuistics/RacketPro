# Phase 5: Extension API & Live Reload

**Date**: 2026-03-08
**Status**: Approved
**Phase**: 5a (of 5a–5d)

## Vision

Extensions are Racket modules that contribute cells, panels, events, menus, and lifecycle hooks to the running IDE. The loader handles registration/unregistration atomically, enabling Smalltalk-style live reload: modify an extension, reload it, see changes immediately — without restarting the IDE.

Racket owns the abstract model (layout tree, cells, event dispatch). The frontend is a rendering projection. Extension authors never touch JS.

## Decisions

- **API surface language**: Racket first, Rhombus bindings later
- **Loading model**: Dynamic require into fresh namespaces
- **Architecture**: Declarative manifest via `define-extension` macro
- **Layout diffing**: ID-based reconciliation (Racket assigns all IDs)
- **Scope**: Extension API + 3 demo extensions. DSLs, custom components, and inspector are Phase 5b–5d.

## Extension Module Contract

An extension is a `.rkt` file that `provide`s an extension descriptor:

```racket
#lang racket/base
(require heavymental/extension)

(define-extension counter-ext
  #:name "Counter"
  #:cells ([count 0])
  #:panels ([#:id "counter" #:label "Counter" #:tab 'bottom
             #:layout (hm-vbox
                        (hm-text #:content "cell:count")
                        (hm-button #:label "+1" #:on-click "increment"))])
  #:events ([#:name "increment"
             #:handler (lambda (msg)
                         (cell-update! 'counter-ext:count add1))])
  #:on-activate (lambda () ...)
  #:on-deactivate (lambda () ...))

(provide counter-ext)
```

### Macro: `define-extension`

```
(define-extension ext-id
  #:name string
  #:cells ([cell-name initial-value] ...)        ; optional
  #:panels ([#:id string #:label string          ; optional
             #:tab 'bottom
             #:layout layout-expr] ...)
  #:events ([#:name string                       ; optional
             #:handler (lambda (msg) ...)] ...)
  #:menus ([#:menu string #:label string         ; optional
            #:shortcut string #:action string] ...)
  #:on-activate (lambda () ...)                  ; optional
  #:on-deactivate (lambda () ...))               ; optional
```

Expands to an `extension-descriptor` struct:

```racket
(struct extension-descriptor
  (id name cells panels events menus on-activate on-deactivate)
  #:transparent)
```

### Namespacing

All cells auto-prefix as `ext-id:cell-name`. All events auto-prefix as `ext-id:event-name`. Layout cell references (`"cell:count"`) are rewritten to `"cell:counter-ext:count"` by the loader. No collisions between extensions.

## Extension Loader

New file: `racket/heavymental-core/extension.rkt`

### API

```racket
(load-extension! path)      ; dynamic-require, register everything
(unload-extension! ext-id)  ; tear down cells, panels, events, menus
(reload-extension! path)    ; unload + load (atomic live reload)
(list-extensions)           ; returns list of loaded descriptors
```

### Loading sequence

1. `dynamic-require` the module into a fresh namespace
2. Extract the `extension-descriptor` from the module's provides
3. Register cells via `cell-register!` (prefixed names)
4. Merge extension panels into the layout tree, assign IDs, re-send `layout:set`
5. Register event handlers into an extension dispatch table keyed by `ext-id:event-name`
6. Merge menu items into the app menu, re-send `menu:set`
7. Call `on-activate` if provided

### Unloading sequence

1. Call `on-deactivate` if provided
2. Remove event handlers from the extension dispatch table
3. Remove extension panels from the layout tree, re-send `layout:set`
4. Unregister cells (send `cell:unregister` messages)
5. Remove menu items, re-send `menu:set`
6. Drop the namespace reference (GC cleans up)

### Live reload

`reload-extension!` = `unload-extension!` then `load-extension!`. Because everything is tracked by `ext-id`, teardown is clean. The user sees the panel rebuild with new behavior.

### Integration with main.rkt

The event dispatcher gets a fallback: if `handle-event` doesn't match a known event name, it checks the extension dispatch table before logging "Unknown event."

New event handlers in `main.rkt`:
- `extension:load` — user requests loading an extension (path in payload)
- `extension:reload` — user requests live reload (ext-id or path in payload)
- `extension:unload` — user requests unloading (ext-id in payload)

## Layout Diffing with Stable IDs

### ID Assignment

Racket owns all layout IDs. Every node in the layout tree carries an `id` prop.

- **Core layout**: `main.rkt` calls `assign-layout-ids` before sending `layout:set`. Auto-generates IDs from type + sibling index (e.g. `"split-0"`, `"editor-0"`, `"terminal-1"`).
- **Extension panels**: Auto-get ID `ext-id:panel-id` from the `define-extension` macro.
- **Explicit IDs**: Racket code can set `'id` in props for well-known nodes.

IDs live in the abstract model, not the DOM. The renderer maps model IDs to DOM elements.

### Diffing Algorithm

The renderer's `setLayout()` becomes a reconciliation pass:

1. Build a map of `id -> existing DOM element` from current children
2. Walk the new layout tree's children:
   - **Has ID in map?** Reuse element, update changed props, recurse into children. Remove from map.
   - **ID not in map?** New node — create element.
3. Elements remaining in the map after the walk: removed by the new layout, destroy them.
4. Reorder DOM children to match the new tree's order via `insertBefore`.

### What this preserves

- Monaco editor instances (internal model, cursor, undo history)
- Terminal sessions (xterm.js state, PTY connection)
- Split pane ratios (user-adjusted)
- Scroll positions within panels

### What gets rebuilt

- Nodes whose type changed at the same ID (shouldn't happen normally)
- New nodes added by extensions
- Removed nodes from unloaded extensions

## Frontend Changes

### `cell:unregister` message

New message type: `{ type: "cell:unregister", name: "ext-id:cell-name" }`. The cell store disposes the signal and removes it from the store. Layout elements referencing the cell go inert.

### Menu merging

`menu:set` continues to work as before — Racket rebuilds the full menu (core + extension items) and re-sends it. No incremental menu API needed.

## New Message Types

| Message | Direction | Purpose |
|---------|-----------|---------|
| `cell:unregister` | Racket -> Frontend | Remove a signal from the cell store |
| `extension:load` | Frontend -> Racket | User requests loading an extension |
| `extension:reload` | Frontend -> Racket | User requests live reload |
| `extension:unload` | Frontend -> Racket | User requests unloading |
| `fs:watch` | Racket -> Rust | Start watching a directory |
| `fs:unwatch` | Racket -> Rust | Stop watching a directory |
| `fs:change` | Rust -> Racket | File system change event |

## Extension API Module

New file: `racket/heavymental-core/api.rkt`

Re-exports cell operations with namespace awareness, plus helper functions:

```racket
(provide current-editor-content    ; request/response: get active editor text
         watch-directory!          ; start FS watcher (via Rust)
         unwatch-all!              ; stop all FS watchers
         cell-ref                  ; re-export
         cell-set!                 ; re-export
         cell-update!)             ; re-export
```

`current-editor-content` uses the existing request/response bridge: sends a request to the frontend, frontend reads Monaco's model, responds.

## Demo Extensions

### Demo 1: Counter Panel

Registers a bottom tab with a counter and increment button. Validates: cells, layout, event handling, panel registration.

### Demo 2: Calc Language

Adds a "Run Calc" menu item. When triggered, reads editor content, evaluates arithmetic expressions, displays result in a cell. Validates: menu extension, editor content access, cell updates.

### Demo 3: File Watcher

Watches the project root directory. Shows recent file changes in a bottom panel. Uses `on-activate`/`on-deactivate` lifecycle hooks to start/stop the watcher. Validates: lifecycle hooks, FS access via Rust, dynamic cell updates.

### FS Watcher Plumbing (for Demo 3)

- **Rust**: New intercepted messages `fs:watch` / `fs:unwatch` using the `notify` crate
- Route `fs:change` events back to Racket via stdin
- **Racket**: `watch-directory!` / `unwatch-all!` wrappers in `api.rkt`

## Implementation Layers

| Layer | What | Depends on |
|-------|------|-----------|
| 1. Core extension infrastructure | `extension.rkt`, `api.rkt`, `main.rkt` updates, `cell.rkt` updates | Nothing |
| 2. Frontend diffing renderer | ID assignment, `setLayout()` rewrite, `cell:unregister` handler | Layer 1 |
| 3. Demo 1 (counter) | Validates cells, layout, events, tabs | Layers 1+2 |
| 4. Demo 2 (calc language) | Validates menus, editor content access | Layers 1+2 |
| 5. Demo 3 (file watcher) + FS plumbing | Validates lifecycle hooks, Rust FS watcher | Layers 1+2 |

## Out of Scope (Phase 5b–5d)

- `#lang heavymental/ui` — DSL sugar over the extension API
- `#lang heavymental/component` — custom Web Components authored from Racket
- Cell/Layout inspector — itself an extension built on this API
- Rhombus bindings — after the Racket API stabilizes
