# Phase 5b: DSLs & Liveness — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add live reload, an extension manager panel, and three DSLs (`heavymental/ui`, `#lang heavymental/extend`, `heavymental/component`) to the HeavyMental IDE.

**Architecture:** Liveness features (tasks 1–4) build on existing FS watcher + extension loader. The `ui` macro (tasks 5–7) transforms S-expressions into layout hasheqs with lambda handler auto-registration. `#lang heavymental/extend` (task 8) is a reader that desugars to `define-extension`. `heavymental/component` (tasks 9–10) defines custom web components from Racket. Demo extensions (task 11) validate everything end-to-end.

**Tech Stack:** Racket (macros, readers, syntax-rules), Rust/Tauri (dialog API, message routing), Lit Web Components, `@preact/signals-core`.

**Collection mapping:** Package dir is `racket/heavymental-core/`, collection name is `"heavymental"` (from `info.rkt`). So `heavymental/ui` → `racket/heavymental-core/ui.rkt`, `heavymental/extend/lang/reader` → `racket/heavymental-core/extend/lang/reader.rkt`.

**Test command:** `racket test/test-extension.rkt` (existing), new test files as noted per task.

---

## Task 1: Live Reload — Auto-Watch on Load/Unload

**Files:**
- Modify: `racket/heavymental-core/extension.rkt`
- Test: `test/test-extension.rkt`

**Context:** `extension.rkt` already has `watch-directory!`, `unwatch-all!`, `load-extension!`, `unload-extension!`. We need `load-extension!` to auto-watch the source file and `unload-extension!` to auto-unwatch it.

**Step 1: Write the failing tests**

Add to `test/test-extension.rkt`:

```racket
;; Test: load-extension! records the source path
(test-case "load-extension! records source path for live reload"
  (reset-extensions!)
  (define test-desc
    (extension-descriptor
     'test-watch "Test Watch" '() '() '() '() #f #f))
  (load-extension-descriptor! test-desc "/tmp/test-ext.rkt")
  (check-equal? (get-extension-source-path 'test-watch) "/tmp/test-ext.rkt")
  (unload-extension! 'test-watch))

;; Test: unload clears source path
(test-case "unload-extension! clears source path"
  (reset-extensions!)
  (define test-desc
    (extension-descriptor
     'test-watch2 "Test Watch 2" '() '() '() '() #f #f))
  (load-extension-descriptor! test-desc "/tmp/test-ext2.rkt")
  (unload-extension! 'test-watch2)
  (check-false (get-extension-source-path 'test-watch2)))
```

**Step 2: Run tests to verify they fail**

Run: `racket test/test-extension.rkt`
Expected: FAIL — `get-extension-source-path` not defined, `load-extension-descriptor!` doesn't accept path argument

**Step 3: Implement source path tracking**

In `extension.rkt`:

1. Add a new hash table `extension-source-paths` (mutable, symbol → string):
```racket
(define extension-source-paths (make-hash))
```

2. Modify `load-extension-descriptor!` to accept an optional `source-path` parameter:
```racket
(define (load-extension-descriptor! desc [source-path #f])
  ;; ... existing cell/event registration code ...
  (when source-path
    (hash-set! extension-source-paths (extension-descriptor-id desc) source-path))
  ;; ... rest of existing code ...
  )
```

3. Modify `unload-extension!` to clear the source path:
```racket
;; Inside unload-extension!, after existing cleanup:
(hash-remove! extension-source-paths ext-id)
```

4. Add getter function:
```racket
(define (get-extension-source-path ext-id)
  (hash-ref extension-source-paths ext-id #f))
```

5. Add to `provide`: `get-extension-source-path`

6. Modify `load-extension!` to pass the path through:
```racket
(define (load-extension! path)
  ;; ... existing dynamic-require code ...
  (load-extension-descriptor! desc path))
```

**Step 4: Run tests to verify they pass**

Run: `racket test/test-extension.rkt`
Expected: All PASS

**Step 5: Commit**

```bash
git add racket/heavymental-core/extension.rkt test/test-extension.rkt
git commit -m "feat: track extension source paths for live reload"
```

---

## Task 2: Live Reload — Debounced Auto-Reload on File Change

**Files:**
- Modify: `racket/heavymental-core/extension.rkt`
- Modify: `racket/heavymental-core/main.rkt`
- Test: `test/test-extension.rkt`

**Context:** When an extension file changes on disk, we debounce (300ms) and call `reload-extension!`. Syntax errors during reload should keep the old version and surface the error. The `fs:change` handler in `main.rkt` currently calls `handle-fs-change` which dispatches to watcher callbacks.

**Step 1: Write the failing tests**

Add to `test/test-extension.rkt`:

```racket
;; Test: watch-extension-file! registers a watcher
(test-case "watch-extension-file! tracks watched extension"
  (reset-extensions!)
  (define output
    (with-output-to-string
      (lambda ()
        (watch-extension-file! 'test-ext "/tmp/test-ext.rkt"))))
  ;; Should have sent an fs:watch message
  (define msgs (parse-all-messages output))
  (check-true (> (length msgs) 0))
  (define watch-msg (find-message-by-type msgs "fs:watch"))
  (check-true (hash? watch-msg)))

;; Test: unwatch-extension-file! removes the watcher
(test-case "unwatch-extension-file! stops watching"
  (reset-extensions!)
  (define output
    (with-output-to-string
      (lambda ()
        (watch-extension-file! 'test-ext "/tmp/test-ext.rkt")
        (unwatch-extension-file! 'test-ext))))
  (check-false (get-extension-watch-id 'test-ext)))

;; Test: reload with syntax error keeps old version
(test-case "reload-extension! with error keeps old version and sets status"
  (reset-extensions!)
  (define test-desc
    (extension-descriptor
     'err-ext "Error Ext" '() '() '() '() #f #f))
  (load-extension-descriptor! test-desc)
  (define output
    (with-output-to-string
      (lambda ()
        (reload-extension! "/tmp/nonexistent-file.rkt"))))
  ;; Old extension should still be loaded
  (check-true (hash-has-key? (list-extensions-hash) 'err-ext)))
```

**Step 2: Run tests to verify they fail**

Run: `racket test/test-extension.rkt`
Expected: FAIL — new functions not defined

**Step 3: Implement auto-watch and safe reload**

In `extension.rkt`:

1. Add extension watch tracking:
```racket
(define extension-watch-ids (make-hash))  ;; ext-id → watch-id

(define (watch-extension-file! ext-id path)
  (define watch-id
    (watch-directory! (path-only path)
                      (lambda (event-type changed-path)
                        (when (equal? (path->string changed-path) (path->string path))
                          (handle-extension-file-change ext-id path)))))
  (hash-set! extension-watch-ids ext-id watch-id))

(define (unwatch-extension-file! ext-id)
  (define watch-id (hash-ref extension-watch-ids ext-id #f))
  (when watch-id
    ;; Send fs:unwatch for this specific watcher
    (send-message! (make-message "fs:unwatch" 'id watch-id))
    (hash-remove! fs-watch-callbacks watch-id)
    (hash-remove! extension-watch-ids ext-id)))

(define (get-extension-watch-id ext-id)
  (hash-ref extension-watch-ids ext-id #f))
```

2. Add debounced reload handler:
```racket
(define pending-reloads (make-hash))  ;; ext-id → thread

(define (handle-extension-file-change ext-id path)
  ;; Cancel any pending reload for this extension
  (define existing (hash-ref pending-reloads ext-id #f))
  (when existing (kill-thread existing))
  ;; Schedule debounced reload
  (hash-set! pending-reloads ext-id
    (thread
      (lambda ()
        (sleep 0.3)  ;; 300ms debounce
        (hash-remove! pending-reloads ext-id)
        (safe-reload-extension! ext-id path)))))
```

3. Add safe reload with error handling:
```racket
(define (safe-reload-extension! ext-id path)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (send-message!
                       (make-message "cell:update"
                         'name "_reload-status"
                         'value (format "Error reloading ~a: ~a"
                                        ext-id (exn-message e)))))])
    (reload-extension! path)
    (send-message!
      (make-message "cell:update"
        'name "_reload-status"
        'value (format "Reloaded ~a" ext-id)))))
```

4. Wire auto-watch into `load-extension!`:
```racket
(define (load-extension! path)
  ;; ... existing dynamic-require + load-extension-descriptor! ...
  (watch-extension-file! ext-id path))
```

5. Wire auto-unwatch into `unload-extension!`:
```racket
;; Inside unload-extension!, add before existing cleanup:
(unwatch-extension-file! ext-id)
```

6. Update `reload-extension!` to properly unload then load:
```racket
(define (reload-extension! path)
  (define existing-id (find-extension-by-path path))
  (when existing-id
    (unload-extension! existing-id))
  (load-extension! path))
```

7. Register `_reload-status` cell in `main.rkt` init:
```racket
(define-cell _reload-status "")
```

8. Add new provides: `watch-extension-file!`, `unwatch-extension-file!`, `get-extension-watch-id`, `safe-reload-extension!`

**Step 4: Run tests to verify they pass**

Run: `racket test/test-extension.rkt`
Expected: All PASS

**Step 5: Commit**

```bash
git add racket/heavymental-core/extension.rkt racket/heavymental-core/main.rkt test/test-extension.rkt
git commit -m "feat: debounced live reload with error handling for extensions"
```

---

## Task 3: Extension Manager — Rust Dialog Plumbing

**Files:**
- Modify: `src-tauri/src/bridge.rs`

**Context:** Rust intercepts certain messages (like `menu:set`, `fs:watch`). We need a new `dialog:open-file` message that opens a native file picker and sends the result back to Racket as `dialog:result`.

**Step 1: Add dialog:open-file handler to bridge.rs**

In the `handle_intercepted_message` function, add a new match arm:

```rust
"dialog:open-file" => {
    let app = app_handle.clone();
    let writer = writer.clone();
    let filter_name = msg.get("filterName")
        .and_then(|v| v.as_str())
        .unwrap_or("Racket files");
    let filter_ext = msg.get("filterExtension")
        .and_then(|v| v.as_str())
        .unwrap_or("rkt");
    let filter_name = filter_name.to_string();
    let filter_ext = filter_ext.to_string();

    std::thread::spawn(move || {
        use tauri::api::dialog::FileDialogBuilder;
        let result = FileDialogBuilder::new()
            .add_filter(&filter_name, &[&filter_ext])
            .pick_file();

        let response = match result {
            Some(path) => serde_json::json!({
                "type": "dialog:result",
                "path": path.to_string_lossy()
            }),
            None => serde_json::json!({
                "type": "dialog:result",
                "path": null
            }),
        };
        let msg_str = format!("{}\n", response.to_string());
        if let Ok(mut w) = writer.lock() {
            let _ = w.write_all(msg_str.as_bytes());
            let _ = w.flush();
        }
    });
    true
}
```

Note: Check the exact Tauri dialog API available in the project's Tauri version. The Tauri v1 API uses `tauri::api::dialog::FileDialogBuilder`. Tauri v2 uses `tauri_plugin_dialog`. Inspect `Cargo.toml` for the version and adjust accordingly. The pattern for sending messages back to Racket can be found in existing intercepted handlers (e.g. how `file:read` sends results back).

**Step 2: Verify it compiles**

Run: `cargo check -p heavy-mental` (from `src-tauri/`)
Expected: Compiles without errors

**Step 3: Commit**

```bash
git add src-tauri/src/bridge.rs
git commit -m "feat: add dialog:open-file message handler in Rust bridge"
```

---

## Task 4: Extension Manager — Racket Side

**Files:**
- Modify: `racket/heavymental-core/main.rkt`
- Modify: `racket/heavymental-core/extension.rkt`
- Test: `test/test-extension.rkt`

**Context:** We need: (1) an `_extensions-list` cell that tracks loaded extensions as a JSON-serializable list, (2) a `dialog:result` handler that loads the selected extension, (3) updating `_extensions-list` whenever extensions load/unload.

**Step 1: Write the failing tests**

Add to `test/test-extension.rkt`:

```racket
;; Test: extensions-list-snapshot returns serializable data
(test-case "extensions-list-snapshot returns list of extension info"
  (reset-extensions!)
  (define test-desc
    (extension-descriptor
     'snap-ext "Snapshot Ext" '() '() '() '() #f #f))
  (load-extension-descriptor! test-desc "/tmp/snap.rkt")
  (define snapshot (extensions-list-snapshot))
  (check-equal? (length snapshot) 1)
  (define entry (car snapshot))
  (check-equal? (hash-ref entry 'id) "snap-ext")
  (check-equal? (hash-ref entry 'name) "Snapshot Ext")
  (check-equal? (hash-ref entry 'path) "/tmp/snap.rkt")
  (check-equal? (hash-ref entry 'status) "active")
  (unload-extension! 'snap-ext))
```

**Step 2: Run tests to verify they fail**

Run: `racket test/test-extension.rkt`
Expected: FAIL — `extensions-list-snapshot` not defined

**Step 3: Implement extensions-list-snapshot**

In `extension.rkt`, add:

```racket
(define (extensions-list-snapshot)
  (for/list ([(id desc) (in-hash loaded-extensions)])
    (hasheq 'id (symbol->string id)
            'name (extension-descriptor-name desc)
            'path (or (get-extension-source-path id) "")
            'status "active")))
```

Add to `provide`: `extensions-list-snapshot`

**Step 4: Wire into main.rkt**

In `main.rkt`:

1. Register the cell at init:
```racket
(define-cell _extensions-list '())
```

2. Create a helper that updates the cell after any extension change:
```racket
(define (update-extensions-list-cell!)
  (cell-set! '_extensions-list (extensions-list-snapshot)))
```

3. Call `update-extensions-list-cell!` after:
   - `extension:load` handler (after `load-extension!` + `rebuild-layout!`)
   - `extension:unload` handler (after `unload-extension!` + `rebuild-layout!`)
   - `extension:reload` handler (after `reload-extension!` + `rebuild-layout!`)

4. Add `dialog:result` handler to the message dispatch in `start-message-loop`:
```racket
["dialog:result"
 (define path (message-ref msg 'path #f))
 (when (and path (not (equal? path 'null)))
   (load-extension! path)
   (rebuild-layout!)
   (update-extensions-list-cell!))]
```

5. Add handler for requesting file dialog:
```racket
;; In extension:load-dialog event handler:
["extension:load-dialog"
 (send-message! (make-message "dialog:open-file"
                              'filterName "Racket files"
                              'filterExtension "rkt"))]
```

**Step 5: Run tests to verify they pass**

Run: `racket test/test-extension.rkt`
Expected: All PASS

**Step 6: Commit**

```bash
git add racket/heavymental-core/extension.rkt racket/heavymental-core/main.rkt test/test-extension.rkt
git commit -m "feat: add extensions-list cell and dialog:result handler"
```

---

## Task 5: Extension Manager — Frontend Component

**Files:**
- Create: `frontend/core/primitives/extension-manager.js`
- Modify: `frontend/core/bridge.js` (only if needed for new message types)

**Context:** New `hm-extension-manager` web component that renders the `_extensions-list` cell as a list with Reload/Unload buttons and a "Load Extension..." button.

**Step 1: Create the component**

Create `frontend/core/primitives/extension-manager.js`:

```javascript
import { LitElement, html, css } from 'lit';
import { getCell } from '../cells.js';
import { dispatch } from '../bridge.js';
import { effect } from '@preact/signals-core';

export class HmExtensionManager extends LitElement {
  static styles = css`
    :host {
      display: block;
      padding: 8px 12px;
      font-family: var(--font-family, system-ui);
      font-size: 13px;
      color: var(--fg, #ccc);
      overflow-y: auto;
    }
    .ext-row {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 4px 0;
      border-bottom: 1px solid var(--border, #333);
    }
    .ext-status {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      flex-shrink: 0;
    }
    .ext-status.active { background: #4CAF50; }
    .ext-status.error { background: #f44336; }
    .ext-name { flex: 1; }
    .ext-btn {
      background: var(--btn-bg, #333);
      color: var(--fg, #ccc);
      border: 1px solid var(--border, #555);
      border-radius: 3px;
      padding: 2px 8px;
      cursor: pointer;
      font-size: 12px;
    }
    .ext-btn:hover { background: var(--btn-hover-bg, #444); }
    .load-btn {
      margin-top: 12px;
      padding: 4px 12px;
    }
  `;

  constructor() {
    super();
    this._extensions = [];
    this._disposeEffect = null;
  }

  connectedCallback() {
    super.connectedCallback();
    const cell = getCell('_extensions-list');
    this._disposeEffect = effect(() => {
      this._extensions = cell.value || [];
      this.requestUpdate();
    });
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._disposeEffect) this._disposeEffect();
  }

  _reload(extId) {
    dispatch('extension:reload', { id: extId });
  }

  _unload(extId) {
    dispatch('extension:unload', { id: extId });
  }

  _loadNew() {
    dispatch('extension:load-dialog', {});
  }

  render() {
    return html`
      ${this._extensions.map(ext => html`
        <div class="ext-row">
          <div class="ext-status ${ext.status || 'active'}"></div>
          <span class="ext-name">${ext.name}</span>
          <button class="ext-btn" @click=${() => this._reload(ext.id)}>Reload</button>
          <button class="ext-btn" @click=${() => this._unload(ext.id)}>Unload</button>
        </div>
      `)}
      <button class="ext-btn load-btn" @click=${this._loadNew}>Load Extension\u2026</button>
    `;
  }
}

customElements.define('hm-extension-manager', HmExtensionManager);
```

**Step 2: Import the component**

Add to the appropriate import location (check how other primitives are imported — likely in `frontend/core/primitives/index.js` or directly in `index.html`). Add:

```javascript
import './primitives/extension-manager.js';
```

**Step 3: Verify it loads**

Run: `cargo tauri dev` — verify no console errors related to the component registration.

**Step 4: Commit**

```bash
git add frontend/core/primitives/extension-manager.js
# Also add any modified import file
git commit -m "feat: add hm-extension-manager web component"
```

---

## Task 6: Extension Manager — Layout Integration

**Files:**
- Modify: `racket/heavymental-core/main.rkt`

**Context:** Add the EXTENSIONS tab to the bottom tabs in the core layout, alongside TERMINAL, PROBLEMS, STEPPER, MACROS.

**Step 1: Add EXTENSIONS tab to the layout**

In `main.rkt`, find the `initial-layout` definition (or wherever the bottom tabs are defined). Look for the `hm-bottom-tabs` node. Add `"EXTENSIONS"` to the tabs list and add a corresponding `hm-tab-content` child with `data-tab-id "extensions"`:

```racket
;; In the bottom-tabs section, add to the tabs list:
;; tabs: '("TERMINAL" "PROBLEMS" "STEPPER" "MACROS" "EXTENSIONS")

;; Add a new tab-content child:
(hasheq 'type "tab-content"
        'props (hasheq 'data-tab-id "extensions")
        'children (list
                    (hasheq 'type "extension-manager"
                            'props (hasheq)
                            'children '())))
```

Note: Check the exact structure of the existing bottom-tabs layout in `main.rkt` to match the pattern used for other tabs (TERMINAL, PROBLEMS, etc.).

**Step 2: Verify the tab appears**

Run: `cargo tauri dev`
Expected: EXTENSIONS tab visible in bottom panel, shows empty list with "Load Extension..." button.

**Step 3: Commit**

```bash
git add racket/heavymental-core/main.rkt
git commit -m "feat: add EXTENSIONS tab to bottom panel"
```

---

## Task 7: UI DSL — Core Macro

**Files:**
- Create: `racket/heavymental-core/ui.rkt`
- Create: `test/test-ui.rkt`

**Context:** The `ui` macro transforms `(ui (vbox (text #:content "hello")))` into the hasheq layout tree that the renderer expects. Auto-prefixes `hm-` to element types.

**Step 1: Write the failing tests**

Create `test/test-ui.rkt`:

```racket
#lang racket/base
(require rackunit
         "../racket/heavymental-core/ui.rkt")

;; Basic element
(test-case "ui: single element with no props"
  (define result (ui (editor)))
  (check-equal? (hash-ref result 'type) "hm-editor")
  (check-equal? (hash-ref result 'children) '()))

;; Element with props
(test-case "ui: element with keyword props"
  (define result (ui (text #:content "hello" #:textStyle "mono")))
  (check-equal? (hash-ref result 'type) "hm-text")
  (check-equal? (hash-ref (hash-ref result 'props) 'content) "hello")
  (check-equal? (hash-ref (hash-ref result 'props) 'textStyle) "mono"))

;; Nested elements
(test-case "ui: nested children"
  (define result (ui (vbox (text #:content "a") (text #:content "b"))))
  (check-equal? (hash-ref result 'type) "hm-vbox")
  (define children (hash-ref result 'children))
  (check-equal? (length children) 2)
  (check-equal? (hash-ref (first children) 'type) "hm-text")
  (check-equal? (hash-ref (second children) 'type) "hm-text"))

;; Deeply nested
(test-case "ui: deeply nested tree"
  (define result
    (ui (vbox
          (hbox
            (button #:label "+1")
            (button #:label "-1"))
          (text #:content "result"))))
  (check-equal? (hash-ref result 'type) "hm-vbox")
  (define children (hash-ref result 'children))
  (check-equal? (length children) 2)
  (define hbox-node (first children))
  (check-equal? (hash-ref hbox-node 'type) "hm-hbox")
  (check-equal? (length (hash-ref hbox-node 'children)) 2))

;; Composable via unquote
(test-case "ui: unquote splices pre-built nodes"
  (define header (ui (toolbar)))
  (define result (ui (vbox ,header (editor))))
  (define children (hash-ref result 'children))
  (check-equal? (length children) 2)
  (check-equal? (hash-ref (first children) 'type) "hm-toolbar"))

;; Element with cell reference in prop
(test-case "ui: cell reference in prop preserved"
  (define result (ui (text #:content "cell:counter")))
  (check-equal? (hash-ref (hash-ref result 'props) 'content) "cell:counter"))
```

**Step 2: Run tests to verify they fail**

Run: `racket test/test-ui.rkt`
Expected: FAIL — `ui.rkt` doesn't exist

**Step 3: Implement the core ui macro**

Create `racket/heavymental-core/ui.rkt`:

```racket
#lang racket/base
(require (for-syntax racket/base racket/list))
(provide ui)

;; ui macro: transforms (ui (type #:key val ... children ...)) into layout hasheq
;;
;; (ui (vbox #:gap "4" (text #:content "hi")))
;; =>
;; (hasheq 'type "hm-vbox"
;;         'props (hasheq 'gap "4")
;;         'children (list (hasheq 'type "hm-text"
;;                                 'props (hasheq 'content "hi")
;;                                 'children '())))

(define-syntax (ui stx)
  (syntax-case stx (unquote)
    [(_ ,expr)
     #'expr]
    [(_ (type args ...))
     #'(ui-node type args ...)]))

(define-syntax (ui-node stx)
  (syntax-case stx ()
    [(_ type args ...)
     (let ()
       (define args-list (syntax->list #'(args ...)))
       ;; Split args into keyword props and children
       (define-values (props children)
         (let loop ([remaining args-list] [props-acc '()] [children-acc '()])
           (cond
             [(null? remaining)
              (values (reverse props-acc) (reverse children-acc))]
             ;; keyword arg: #:key val
             [(keyword? (syntax-e (car remaining)))
              (when (null? (cdr remaining))
                (raise-syntax-error 'ui "keyword missing value" (car remaining)))
              (loop (cddr remaining)
                    (cons (list (car remaining) (cadr remaining)) props-acc)
                    children-acc)]
             ;; child expression
             [else
              (loop (cdr remaining)
                    props-acc
                    (cons (car remaining) children-acc))])))
       (define type-str
         (string-append "hm-" (symbol->string (syntax-e #'type))))
       (define props-expr
         (if (null? props)
             #'(hasheq)
             (with-syntax ([(kv ...) (apply append
                                      (map (lambda (p)
                                             (list
                                               (datum->syntax stx
                                                 (string->symbol
                                                   (keyword->string
                                                     (syntax-e (car p)))))
                                               (cadr p)))
                                           props))])
               #'(hasheq 'kv ...))))
       (define children-exprs
         (map (lambda (child)
                (syntax-case child (unquote)
                  [,expr #'expr]
                  [(child-type child-args ...)
                   #'(ui-node child-type child-args ...)]
                  [expr #'expr]))
              children))
       (with-syntax ([type-s (datum->syntax stx type-str)]
                     [props-e props-expr]
                     [(child-e ...) children-exprs])
         #'(hasheq 'type type-s
                   'props props-e
                   'children (list child-e ...))))]))
```

Note: The `hasheq` with alternating `'key val` pairs is the existing pattern. The macro needs to properly interleave `'symbol value` pairs. Check exact syntax by looking at how layout hasheqs are built in `main.rkt` and extension descriptors.

**Step 4: Run tests to verify they pass**

Run: `racket test/test-ui.rkt`
Expected: All PASS

**Step 5: Commit**

```bash
git add racket/heavymental-core/ui.rkt test/test-ui.rkt
git commit -m "feat: add heavymental/ui embedded DSL macro"
```

---

## Task 8: UI DSL — Lambda Handler Auto-Registration

**Files:**
- Modify: `racket/heavymental-core/ui.rkt`
- Create or modify: `racket/heavymental-core/handler-registry.rkt`
- Test: `test/test-ui.rkt`

**Context:** When a handler prop (`#:on-click`, `#:on-change`, etc.) has a lambda value instead of a string, the `ui` macro should auto-register it in a handler table and substitute a `_h:N` string ID.

**Step 1: Write the failing tests**

Add to `test/test-ui.rkt`:

```racket
(require "../racket/heavymental-core/handler-registry.rkt")

;; Test: string handlers pass through unchanged
(test-case "ui: string on-click handler passes through"
  (define result (ui (button #:label "Go" #:on-click "my-event")))
  (check-equal? (hash-ref (hash-ref result 'props) 'on-click) "my-event"))

;; Test: lambda handler gets auto-registered
(test-case "ui: lambda on-click handler auto-registered"
  (clear-auto-handlers!)
  (define result (ui (button #:label "Go" #:on-click (lambda () (void)))))
  (define handler-id (hash-ref (hash-ref result 'props) 'on-click))
  (check-true (string-prefix? handler-id "_h:"))
  ;; Handler should be in the registry
  (check-true (procedure? (get-auto-handler handler-id))))

;; Test: handler with msg argument works
(test-case "ui: lambda with msg arg auto-registered"
  (clear-auto-handlers!)
  (define called? (box #f))
  (define result
    (ui (button #:on-click (lambda (msg) (set-box! called? #t)))))
  (define handler-id (hash-ref (hash-ref result 'props) 'on-click))
  (define handler (get-auto-handler handler-id))
  ;; Call it with a fake message
  (handler (hasheq 'type "event"))
  (check-true (unbox called?)))

;; Test: zero-arg handler called without msg
(test-case "ui: zero-arg lambda called correctly"
  (clear-auto-handlers!)
  (define counter (box 0))
  (define result
    (ui (button #:on-click (lambda () (set-box! counter (add1 (unbox counter)))))))
  (define handler-id (hash-ref (hash-ref result 'props) 'on-click))
  (define handler (get-auto-handler handler-id))
  ;; The dispatch wrapper should call with no args
  (handler (hasheq))  ;; dispatch sends msg, wrapper adapts arity
  (check-equal? (unbox counter) 1))
```

**Step 2: Run tests to verify they fail**

Run: `racket test/test-ui.rkt`
Expected: FAIL — `handler-registry.rkt` doesn't exist

**Step 3: Create handler registry**

Create `racket/heavymental-core/handler-registry.rkt`:

```racket
#lang racket/base
(provide register-auto-handler!
         get-auto-handler
         clear-auto-handlers!
         collect-handler-ids
         remove-handlers!)

(define auto-handlers (make-hash))  ;; string "_h:N" → procedure
(define handler-counter 0)

(define (register-auto-handler! proc)
  (set! handler-counter (add1 handler-counter))
  (define id (format "_h:~a" handler-counter))
  ;; Wrap to handle arity: if proc takes 0 args, ignore the msg
  (define wrapped
    (if (procedure-arity-includes? proc 1)
        proc
        (lambda (msg) (proc))))
  (hash-set! auto-handlers id wrapped)
  id)

(define (get-auto-handler id)
  (hash-ref auto-handlers id #f))

(define (clear-auto-handlers!)
  (hash-clear! auto-handlers)
  (set! handler-counter 0))

(define (remove-handlers! ids)
  (for ([id (in-list ids)])
    (hash-remove! auto-handlers id)))

;; Walk a layout tree and collect all _h: handler IDs from props
(define (collect-handler-ids layout)
  (cond
    [(not (hash? layout)) '()]
    [else
     (define props (hash-ref layout 'props (hasheq)))
     (define prop-ids
       (for/list ([(k v) (in-hash props)]
                  #:when (and (string? v) (string-prefix? v "_h:")))
         v))
     (define children (hash-ref layout 'children '()))
     (define child-ids
       (apply append (map collect-handler-ids children)))
     (append prop-ids child-ids)]))
```

**Step 4: Wire handlers into ui macro**

Modify `racket/heavymental-core/ui.rkt` to detect non-string handler values at runtime. Since we can't always tell at macro-expansion time whether a value is a lambda or string, use a runtime wrapper:

Add to `ui.rkt`:
```racket
(require "handler-registry.rkt")
(provide ui-resolve-handler)

(define (ui-resolve-handler val)
  (cond
    [(string? val) val]
    [(procedure? val) (register-auto-handler! val)]
    [else (error 'ui "handler must be a string or procedure, got: ~v" val)]))
```

Modify the macro's prop handling: for props whose keyword starts with `on-` (like `#:on-click`, `#:on-change`), wrap the value expression with `(ui-resolve-handler ...)`:

```racket
;; In the props-expr building section, detect on-* keywords:
(define (handler-keyword? kw)
  (string-prefix? (keyword->string kw) "on-"))

;; For handler props, wrap the value:
;; 'on-click (ui-resolve-handler expr)
;; For non-handler props:
;; 'prop-name expr
```

**Step 5: Run tests to verify they pass**

Run: `racket test/test-ui.rkt`
Expected: All PASS

**Step 6: Commit**

```bash
git add racket/heavymental-core/handler-registry.rkt racket/heavymental-core/ui.rkt test/test-ui.rkt
git commit -m "feat: auto-register lambda handlers in ui macro with arity detection"
```

---

## Task 9: UI DSL — Handler Cleanup on Layout Send

**Files:**
- Modify: `racket/heavymental-core/main.rkt`
- Modify: `racket/heavymental-core/extension.rkt`
- Test: `test/test-ui.rkt`

**Context:** When `rebuild-layout!` sends a new layout, walk the old and new trees to find `_h:*` IDs. Delete handlers that are in the old tree but not the new tree.

**Step 1: Write the failing tests**

Add to `test/test-ui.rkt`:

```racket
(require "../racket/heavymental-core/handler-registry.rkt")

;; Test: collect-handler-ids finds _h: IDs in layout tree
(test-case "collect-handler-ids extracts handler IDs"
  (define layout
    (hasheq 'type "hm-vbox"
            'props (hasheq)
            'children
            (list (hasheq 'type "hm-button"
                          'props (hasheq 'on-click "_h:1" 'label "Go")
                          'children '())
                  (hasheq 'type "hm-button"
                          'props (hasheq 'on-click "_h:2")
                          'children '()))))
  (define ids (collect-handler-ids layout))
  (check-equal? (sort ids string<?) '("_h:1" "_h:2")))

;; Test: remove-handlers! cleans up
(test-case "remove-handlers! deletes from registry"
  (clear-auto-handlers!)
  (define id1 (register-auto-handler! (lambda () (void))))
  (define id2 (register-auto-handler! (lambda () (void))))
  (check-true (procedure? (get-auto-handler id1)))
  (remove-handlers! (list id1))
  (check-false (get-auto-handler id1))
  (check-true (procedure? (get-auto-handler id2))))
```

**Step 2: Run tests to verify they fail (or pass if already implemented)**

Run: `racket test/test-ui.rkt`

**Step 3: Wire cleanup into rebuild-layout!**

In `main.rkt`, modify `rebuild-layout!`:

```racket
(require "handler-registry.rkt")

(define previous-layout #f)  ;; track the last sent layout

(define (rebuild-layout!)
  ;; ... existing: build new-layout from initial-layout + extension panels + assign-layout-ids ...

  ;; Cleanup orphaned handlers
  (when previous-layout
    (define old-ids (collect-handler-ids previous-layout))
    (define new-ids (collect-handler-ids new-layout))
    (define orphaned (remove* new-ids old-ids equal?))
    (when (not (null? orphaned))
      (remove-handlers! orphaned)))
  (set! previous-layout new-layout)

  ;; ... existing: send layout:set message ...
  )
```

**Step 4: Wire handler dispatch into event loop**

In `main.rkt`, modify the event dispatch fallback (where unknown events check extension handlers) to also check auto-handlers:

```racket
;; In the event dispatch fallback:
(define auto-handler (get-auto-handler event-name))
(cond
  [auto-handler (auto-handler msg)]
  [(get-extension-handler event-name) => (lambda (h) (h msg))]
  [else (log-warning "Unknown event: ~a" event-name)])
```

**Step 5: Run all tests**

Run: `racket test/test-ui.rkt && racket test/test-extension.rkt`
Expected: All PASS

**Step 6: Commit**

```bash
git add racket/heavymental-core/main.rkt racket/heavymental-core/handler-registry.rkt test/test-ui.rkt
git commit -m "feat: cleanup orphaned lambda handlers on layout rebuild"
```

---

## Task 10: `#lang heavymental/extend` — Reader Module

**Files:**
- Create: `racket/heavymental-core/extend/lang/reader.rkt`
- Create: `test/test-extend-lang.rkt`

**Context:** `#lang heavymental/extend` is a reader that parses a simplified surface syntax into a `define-extension` form. The collection is `"heavymental"`, so the reader goes at `racket/heavymental-core/extend/lang/reader.rkt`.

**Step 1: Write the failing test**

Create `test/test-extend-lang.rkt`:

```racket
#lang racket/base
(require rackunit)

;; Test the reader by requiring a test extension written in the DSL
;; First, create a test extension file that uses #lang heavymental/extend

;; For now, test the parser function directly
(require "../racket/heavymental-core/extend/parser.rkt")

(test-case "parse-extend: name declaration"
  (define result
    (parse-extend-source
     '((name: "Test Extension")
       (cell count = 0)
       (event increment (cell-update! 'count add1)))))
  (check-equal? (hash-ref result 'name) "Test Extension")
  (check-equal? (length (hash-ref result 'cells)) 1)
  (check-equal? (length (hash-ref result 'events)) 1))

(test-case "parse-extend: full extension"
  (define result
    (parse-extend-source
     '((name: "Full")
       (cell count = 0)
       (cell label = "hello")
       (panel counter "Counter" bottom
         (hm-vbox (hm-text #:content "cell:count")))
       (event increment (cell-update! 'count add1))
       (menu "Tools" "Run" "Cmd+R" run-action)
       (on-activate (displayln "loaded"))
       (on-deactivate (displayln "unloaded")))))
  (check-equal? (hash-ref result 'name) "Full")
  (check-equal? (length (hash-ref result 'cells)) 2)
  (check-equal? (length (hash-ref result 'panels)) 1)
  (check-equal? (length (hash-ref result 'events)) 1)
  (check-equal? (length (hash-ref result 'menus)) 1))
```

**Step 2: Run tests to verify they fail**

Run: `racket test/test-extend-lang.rkt`
Expected: FAIL — parser module doesn't exist

**Step 3: Create the parser**

Create `racket/heavymental-core/extend/parser.rkt`:

This module parses the list of declarations into a hash that maps to `define-extension` keyword args. The reader will use this to generate the macro call.

```racket
#lang racket/base
(provide parse-extend-source)

(define (parse-extend-source decls)
  (define result (make-hash))
  (hash-set! result 'name #f)
  (hash-set! result 'cells '())
  (hash-set! result 'panels '())
  (hash-set! result 'events '())
  (hash-set! result 'menus '())
  (hash-set! result 'on-activate #f)
  (hash-set! result 'on-deactivate #f)

  (for ([decl (in-list decls)])
    (match (car decl)
      ['name: (hash-set! result 'name (cadr decl))]
      ['cell
       (hash-update! result 'cells
         (lambda (cs)
           (cons (list (list-ref decl 1) (list-ref decl 3)) cs)))]
      ['panel
       (hash-update! result 'panels
         (lambda (ps)
           (cons (list (list-ref decl 1)   ;; id
                       (list-ref decl 2)   ;; label
                       (list-ref decl 3)   ;; tab
                       (list-ref decl 4))  ;; layout
                 ps)))]
      ['event
       (hash-update! result 'events
         (lambda (es)
           (cons (list (list-ref decl 1)   ;; name
                       (list-ref decl 2))  ;; handler body
                 es)))]
      ['menu
       (hash-update! result 'menus
         (lambda (ms)
           (cons (list (list-ref decl 1)   ;; menu
                       (list-ref decl 2)   ;; label
                       (list-ref decl 3)   ;; shortcut
                       (list-ref decl 4))  ;; action
                 ms)))]
      ['on-activate
       (hash-set! result 'on-activate (cadr decl))]
      ['on-deactivate
       (hash-set! result 'on-deactivate (cadr decl))]))

  ;; Reverse lists to maintain declaration order
  (hash-update! result 'cells reverse)
  (hash-update! result 'panels reverse)
  (hash-update! result 'events reverse)
  (hash-update! result 'menus reverse)
  result)
```

**Step 4: Create the reader module**

Create directories: `racket/heavymental-core/extend/lang/`

Create `racket/heavymental-core/extend/lang/reader.rkt`:

```racket
#lang racket/base
(require syntax/strip-context)
(provide (rename-out [extend-read read]
                     [extend-read-syntax read-syntax]))

(define (extend-read in)
  (syntax->datum (extend-read-syntax #f in)))

(define (extend-read-syntax src in)
  (define decls (read-extend-declarations in))
  (define ext-id (or (find-extension-id decls) 'extension))
  (strip-context
   #`(module #,ext-id racket/base
       (require heavymental/extension)
       (require heavymental/ui)
       #,(generate-define-extension ext-id decls)
       (provide #,ext-id))))

;; Read all declarations from the input port
(define (read-extend-declarations in)
  ;; Each declaration is a top-level form
  (let loop ([decls '()])
    (define form (read-syntax 'extend in))
    (if (eof-object? form)
        (reverse decls)
        (loop (cons (syntax->datum form) decls)))))

;; Derive extension id from the name
(define (find-extension-id decls)
  (for/or ([d (in-list decls)])
    (and (pair? d) (eq? (car d) 'name:)
         (string->symbol
           (string-downcase
             (regexp-replace* #rx" " (cadr d) "-"))))))

;; Generate the define-extension form from parsed declarations
(define (generate-define-extension ext-id decls)
  ;; ... builds the define-extension S-expression from parsed decls ...
  ;; This generates the full (define-extension ext-id #:name "..." ...) form
  'TODO)
```

Note: The exact implementation of `generate-define-extension` needs to map each parsed declaration type to the corresponding `define-extension` keyword. This is the core logic — implement it following the patterns in `define-extension` macro usage shown in the demo extensions.

**Step 5: Run tests to verify they pass**

Run: `racket test/test-extend-lang.rkt`
Expected: All PASS

**Step 6: Commit**

```bash
git add racket/heavymental-core/extend/ test/test-extend-lang.rkt
git commit -m "feat: add #lang heavymental/extend reader and parser"
```

---

## Task 11: Custom Components — Racket Macro

**Files:**
- Create: `racket/heavymental-core/component.rkt`
- Create: `test/test-component.rkt`

**Context:** `define-component` macro produces a component descriptor. At runtime, sends `component:register` to the frontend.

**Step 1: Write the failing tests**

Create `test/test-component.rkt`:

```racket
#lang racket/base
(require rackunit
         "../racket/heavymental-core/component.rkt")

;; Test: define-component creates a descriptor
(test-case "define-component creates component descriptor"
  (define-component test-comp
    #:tag "hm-test-comp"
    #:properties ([value "default"])
    #:template "<div>${value}</div>"
    #:style ":host { display: block; }"
    #:script "updated(props) {}")
  (check-true (component-descriptor? test-comp))
  (check-equal? (component-descriptor-tag test-comp) "hm-test-comp")
  (check-equal? (length (component-descriptor-properties test-comp)) 1))

;; Test: register-component! sends message
(test-case "register-component! sends component:register message"
  (define-component reg-comp
    #:tag "hm-reg-comp"
    #:properties ([data '()])
    #:template "<span>test</span>"
    #:style ""
    #:script "")
  (define output
    (with-output-to-string
      (lambda ()
        (register-component! reg-comp))))
  (define msgs (parse-all-messages output))
  (define reg-msg (find-message-by-type msgs "component:register"))
  (check-true (hash? reg-msg))
  (check-equal? (hash-ref reg-msg 'tag) "hm-reg-comp"))

;; Test: unregister-component! sends message
(test-case "unregister-component! sends component:unregister message"
  (define output
    (with-output-to-string
      (lambda ()
        (unregister-component! "hm-reg-comp"))))
  (define msgs (parse-all-messages output))
  (define unreg-msg (find-message-by-type msgs "component:unregister"))
  (check-true (hash? unreg-msg))
  (check-equal? (hash-ref unreg-msg 'tag) "hm-reg-comp"))

;; Test: template can be a layout tree (from ui macro)
(test-case "define-component with layout tree template"
  (require "../racket/heavymental-core/ui.rkt")
  (define-component tree-comp
    #:tag "hm-tree-comp"
    #:properties ([height 32])
    #:template (ui (vbox (text #:content "hello")))
    #:style ""
    #:script "")
  (check-true (hash? (component-descriptor-template tree-comp))))
```

**Step 2: Run tests to verify they fail**

Run: `racket test/test-component.rkt`
Expected: FAIL — `component.rkt` doesn't exist

**Step 3: Implement component.rkt**

Create `racket/heavymental-core/component.rkt`:

```racket
#lang racket/base
(require "protocol.rkt")
(require (for-syntax racket/base))

(provide define-component
         component-descriptor?
         component-descriptor-tag
         component-descriptor-properties
         component-descriptor-template
         component-descriptor-style
         component-descriptor-script
         register-component!
         unregister-component!)

(struct component-descriptor
  (tag properties template style script)
  #:transparent)

(define-syntax (define-component stx)
  (syntax-case stx ()
    [(_ name
        #:tag tag-expr
        #:properties ([prop-name prop-default] ...)
        #:template template-expr
        #:style style-expr
        #:script script-expr)
     #'(define name
         (component-descriptor
          tag-expr
          (list (list 'prop-name prop-default) ...)
          template-expr
          style-expr
          script-expr))]))

(define (register-component! comp)
  (send-message!
    (make-message "component:register"
      'tag (component-descriptor-tag comp)
      'properties (map (lambda (p) (hasheq 'name (symbol->string (car p))
                                           'default (cadr p)))
                       (component-descriptor-properties comp))
      'template (let ([t (component-descriptor-template comp)])
                  (if (hash? t) t  ;; layout tree from ui macro
                      t))          ;; string HTML
      'style (component-descriptor-style comp)
      'script (component-descriptor-script comp))))

(define (unregister-component! tag)
  (send-message!
    (make-message "component:unregister"
      'tag tag)))
```

**Step 4: Run tests to verify they pass**

Run: `racket test/test-component.rkt`
Expected: All PASS

**Step 5: Commit**

```bash
git add racket/heavymental-core/component.rkt test/test-component.rkt
git commit -m "feat: add define-component macro and register/unregister"
```

---

## Task 12: Custom Components — Frontend Registry

**Files:**
- Create: `frontend/core/component-registry.js`
- Modify: `frontend/core/bridge.js` or appropriate init file

**Context:** When the frontend receives `component:register`, it dynamically defines a new custom element. `component:unregister` removes it (or makes it inert — `customElements.define` can't be undone, so we track registered tags).

**Step 1: Create component-registry.js**

```javascript
import { LitElement, html, css } from 'lit';
import { getCell, resolveValue } from './cells.js';
import { onMessage } from './bridge.js';
import { effect } from '@preact/signals-core';

const registeredComponents = new Map();

export function initComponentRegistry() {
  onMessage('component:register', (msg) => {
    registerComponent(msg);
  });

  onMessage('component:unregister', (msg) => {
    unregisterComponent(msg.tag);
  });
}

function registerComponent({ tag, properties, template, style, script }) {
  if (registeredComponents.has(tag)) {
    console.warn(`Component ${tag} already registered, skipping`);
    return;
  }

  // Parse the script to extract lifecycle methods
  const scriptFn = script ? new Function('self', `
    const methods = {};
    ${script.replace(/^(\w+)\s*\(/, 'methods.$1 = function(')}
    return methods;
  `) : () => ({});

  // Build property definitions for Lit
  const propDefs = {};
  const defaults = {};
  for (const { name, default: def } of properties) {
    propDefs[name] = { type: typeof def === 'number' ? Number : String };
    defaults[name] = def;
  }

  // Create the class
  const ComponentClass = class extends LitElement {
    static properties = propDefs;

    static styles = css([style || '']);

    constructor() {
      super();
      for (const [name, def] of Object.entries(defaults)) {
        this[name] = def;
      }
      this._methods = {};
      this._cellEffects = [];
    }

    connectedCallback() {
      super.connectedCallback();
      try { this._methods = scriptFn(this); } catch(e) { console.error(e); }
      if (this._methods.connected) this._methods.connected.call(this);

      // Set up cell subscriptions for cell-reference properties
      for (const { name } of properties) {
        const val = defaults[name];
        if (typeof val === 'string' && val.startsWith('cell:')) {
          const cellName = val.slice(5);
          const dispose = effect(() => {
            this[name] = getCell(cellName).value;
            this.requestUpdate();
          });
          this._cellEffects.push(dispose);
        }
      }
    }

    disconnectedCallback() {
      super.disconnectedCallback();
      if (this._methods.disconnected) this._methods.disconnected.call(this);
      this._cellEffects.forEach(d => d());
    }

    updated() {
      if (this._methods.updated) {
        const props = {};
        for (const { name } of properties) {
          props[name] = this[name];
        }
        this._methods.updated.call(this, props);
      }
    }

    render() {
      if (typeof template === 'object' && template.type) {
        // Layout tree from ui macro — render as nested elements
        return this._renderLayoutTree(template);
      }
      // String template — simple interpolation
      let processed = template || '';
      for (const { name } of properties) {
        processed = processed.replaceAll(`\${${name}}`, this[name] ?? '');
      }
      const tpl = document.createElement('template');
      tpl.innerHTML = processed;
      return html`${tpl.content.cloneNode(true)}`;
    }

    _renderLayoutTree(node) {
      // Delegate to main renderer's createNode logic
      // For simplicity, create elements directly
      const el = document.createElement(node.type);
      if (node.props) {
        for (const [k, v] of Object.entries(node.props)) {
          el.setAttribute(k, v);
        }
      }
      return html`${el}`;
    }
  };

  customElements.define(tag, ComponentClass);
  registeredComponents.set(tag, ComponentClass);
}

function unregisterComponent(tag) {
  // Can't truly undefine a custom element, but we can track it
  registeredComponents.delete(tag);
  // Existing instances remain in DOM but won't be re-created
}
```

**Step 2: Wire into initialization**

Import and call `initComponentRegistry()` in the appropriate init location (check where `initCells()` is called — likely in `frontend/core/app.js` or a similar init module):

```javascript
import { initComponentRegistry } from './component-registry.js';
// In init:
initComponentRegistry();
```

**Step 3: Verify no errors**

Run: `cargo tauri dev` — check console for errors.

**Step 4: Commit**

```bash
git add frontend/core/component-registry.js
# Also add any modified init file
git commit -m "feat: add frontend component registry for dynamic custom elements"
```

---

## Task 13: Update Demo Extensions + Integration Test

**Files:**
- Create: `extensions/counter-ui.rkt` (counter rewritten with `ui` macro)
- Create: `extensions/hello-component.rkt` (demo extension using `define-component`)
- Create: `test/test-phase5b-integration.rkt`

**Context:** Rewrite one demo extension to use the new `ui` macro (validating it works end-to-end), create a new demo showing `define-component`, and write integration tests.

**Step 1: Create counter-ui.rkt using the ui macro**

Create `extensions/counter-ui.rkt`:

```racket
#lang racket/base
(require heavymental/extension
         heavymental/ui)

(define-extension counter-ui-ext
  #:name "Counter (UI DSL)"
  #:cells ([count 0])
  #:panels ([#:id "counter-ui" #:label "Counter UI" #:tab 'bottom
             #:layout (ui
                        (vbox
                          (text #:content "cell:count")
                          (hbox
                            (button #:label "+1"
                                    #:on-click (lambda () (cell-update! 'counter-ui-ext:count add1)))
                            (button #:label "Reset"
                                    #:on-click (lambda () (cell-set! 'counter-ui-ext:count 0))))))])
  #:events ())

(provide counter-ui-ext)
```

**Step 2: Create hello-component.rkt**

Create `extensions/hello-component.rkt`:

```racket
#lang racket/base
(require heavymental/extension
         heavymental/component
         heavymental/ui)

(define-component hm-greeting
  #:tag "hm-greeting"
  #:properties ([name "World"])
  #:template "<div class='greeting'>Hello, ${name}!</div>"
  #:style "
    :host { display: block; }
    .greeting { font-size: 18px; color: #4CAF50; padding: 8px; }
  "
  #:script "
    updated(props) {
      console.log('Greeting updated:', props.name);
    }
  ")

(define-extension hello-ext
  #:name "Hello Component"
  #:cells ([greeting-name "World"])
  #:panels ([#:id "hello" #:label "Hello" #:tab 'bottom
             #:layout (ui
                        (vbox
                          (text #:content "cell:greeting-name")))])
  #:on-activate (lambda () (register-component! hm-greeting))
  #:on-deactivate (lambda () (unregister-component! "hm-greeting")))

(provide hello-ext)
```

**Step 3: Write integration tests**

Create `test/test-phase5b-integration.rkt`:

```racket
#lang racket/base
(require rackunit
         json
         "../racket/heavymental-core/ui.rkt"
         "../racket/heavymental-core/handler-registry.rkt"
         "../racket/heavymental-core/component.rkt"
         "../racket/heavymental-core/extension.rkt"
         "../racket/heavymental-core/cell.rkt"
         "../racket/heavymental-core/protocol.rkt")

;; Helper: parse messages from captured output
(define (parse-all-messages str)
  (with-input-from-string str
    (lambda ()
      (let loop ([msgs '()])
        (define line (read-line))
        (if (eof-object? line)
            (reverse msgs)
            (with-handlers ([exn:fail? (lambda (e) (loop msgs))])
              (loop (cons (string->jsexpr line) msgs))))))))

(define (find-message-by-type msgs type)
  (for/or ([m (in-list msgs)])
    (and (hash? m) (equal? (hash-ref m 'type #f) type) m)))

;; Integration: ui macro + handler registry round-trip
(test-case "integration: ui macro with lambda handlers produces valid layout"
  (clear-auto-handlers!)
  (define layout
    (ui (vbox
          (button #:label "Click"
                  #:on-click (lambda () (void)))
          (text #:content "cell:test"))))
  ;; Layout should be a valid hasheq tree
  (check-equal? (hash-ref layout 'type) "hm-vbox")
  (define children (hash-ref layout 'children))
  (check-equal? (length children) 2)
  ;; Button's on-click should be a registered handler ID
  (define btn (first children))
  (define handler-id (hash-ref (hash-ref btn 'props) 'on-click))
  (check-true (string-prefix? handler-id "_h:"))
  (check-true (procedure? (get-auto-handler handler-id))))

;; Integration: handler cleanup
(test-case "integration: handler cleanup removes orphans"
  (clear-auto-handlers!)
  ;; Build layout with handler
  (define layout1
    (ui (button #:on-click (lambda () (void)))))
  (define id1 (hash-ref (hash-ref layout1 'props) 'on-click))
  ;; Build replacement layout without that handler
  (define layout2
    (ui (button #:on-click "static-event")))
  ;; Simulate cleanup
  (define old-ids (collect-handler-ids layout1))
  (define new-ids (collect-handler-ids layout2))
  (define orphaned (remove* new-ids old-ids equal?))
  (remove-handlers! orphaned)
  ;; Old handler should be gone
  (check-false (get-auto-handler id1)))

;; Integration: component descriptor + register message
(test-case "integration: component registers and produces message"
  (define-component test-int-comp
    #:tag "hm-test-int"
    #:properties ([size 100])
    #:template (ui (vbox (text #:content "component")))
    #:style ":host { display: block; }"
    #:script "")
  (define output
    (with-output-to-string
      (lambda () (register-component! test-int-comp))))
  (define msgs (parse-all-messages output))
  (define reg-msg (find-message-by-type msgs "component:register"))
  (check-true (hash? reg-msg))
  (check-equal? (hash-ref reg-msg 'tag) "hm-test-int")
  ;; Template should be a layout tree
  (check-true (hash? (hash-ref reg-msg 'template))))

;; Integration: extension with live reload status
(test-case "integration: extensions-list-snapshot after load"
  (reset-extensions!)
  (define output
    (with-output-to-string
      (lambda ()
        (load-extension-descriptor!
         (extension-descriptor 'int-ext "Integration" '() '() '() '() #f #f)
         "/tmp/int.rkt"))))
  (define snapshot (extensions-list-snapshot))
  (check-equal? (length snapshot) 1)
  (check-equal? (hash-ref (car snapshot) 'name) "Integration")
  (unload-extension! 'int-ext))
```

**Step 4: Run all tests**

```bash
racket test/test-ui.rkt && racket test/test-component.rkt && racket test/test-phase5b-integration.rkt && racket test/test-extension.rkt
```

Expected: All PASS

**Step 5: Commit**

```bash
git add extensions/counter-ui.rkt extensions/hello-component.rkt test/test-phase5b-integration.rkt
git commit -m "feat: add demo extensions using ui macro and define-component"
```

---

## Task Summary

| # | Task | Key files | Depends on |
|---|------|-----------|------------|
| 1 | Live reload — source path tracking | extension.rkt | — |
| 2 | Live reload — debounced auto-reload | extension.rkt, main.rkt | Task 1 |
| 3 | Extension manager — Rust dialog | bridge.rs | — |
| 4 | Extension manager — Racket side | main.rkt, extension.rkt | Task 3 |
| 5 | Extension manager — frontend component | extension-manager.js | Task 4 |
| 6 | Extension manager — layout integration | main.rkt | Task 5 |
| 7 | UI DSL — core macro | ui.rkt | — |
| 8 | UI DSL — lambda handlers | ui.rkt, handler-registry.rkt | Task 7 |
| 9 | UI DSL — handler cleanup | main.rkt | Task 8 |
| 10 | `#lang heavymental/extend` reader | extend/lang/reader.rkt | Task 7 |
| 11 | Custom components — Racket macro | component.rkt | — |
| 12 | Custom components — frontend registry | component-registry.js | Task 11 |
| 13 | Demo extensions + integration tests | extensions/*.rkt, tests | Tasks 7-12 |

## Parallelization Guide

These task groups can run in parallel (separate worktrees):
- **Group A**: Tasks 1-2 (live reload) — modifies extension.rkt, main.rkt
- **Group B**: Tasks 3, 5 (Rust dialog + frontend component) — modifies bridge.rs, creates JS
- **Group C**: Tasks 7-8 (UI DSL core) — creates ui.rkt, handler-registry.rkt

After Group A+B+C converge:
- **Group D**: Tasks 4, 6, 9 (wire everything together in main.rkt)
- **Group E**: Tasks 10, 11, 12 (#lang extend + components)

Final:
- **Task 13**: Integration tests (after all groups)
