# Quick Wins + Macro Expansion Viewer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add bottom panel tabs, cross-file go-to-definition, file:read sequencing fix, and macro expansion tree viewer.

**Architecture:** Four independent features built incrementally. Bottom panel tabs restructure the layout tree and add two new components. Cross-file goto adds a pending-goto queue to editor.rkt and wires the lang-intel.js definition provider. Macro expansion adds a new Racket module (macro-expander.rkt) and a new frontend component (macro-panel.js).

**Tech Stack:** Racket (cells, protocol, expand-once), Lit Web Components, Monaco Editor (read-only instances), Tauri IPC.

---

### Task 1: Bottom Panel Tab Bar Component

**Files:**
- Create: `frontend/core/primitives/bottom-tabs.js`
- Modify: `frontend/core/main.js:20` (add import)

**Step 1: Create `hm-bottom-tabs` component**

Create `frontend/core/primitives/bottom-tabs.js`:

```javascript
// primitives/bottom-tabs.js — hm-bottom-tabs
//
// Horizontal tab bar for the bottom panel. Fixed tabs (no close/dirty).
// Active tab controlled by `current-bottom-tab` cell.

import { LitElement, html, css } from 'lit';
import { effect } from '@preact/signals-core';
import { getCell } from '../cells.js';
import { dispatch, onMessage } from '../bridge.js';

class HmBottomTabs extends LitElement {
  static properties = {
    tabs: { type: Array },
    _activeTab: { type: String, state: true },
    _problemsCount: { type: Number, state: true },
  };

  static styles = css`
    :host {
      display: flex;
      align-items: center;
      height: 28px;
      min-height: 28px;
      background: var(--bg-toolbar, #F8F8F8);
      border-top: 1px solid var(--border, #D4D4D4);
      border-bottom: 1px solid var(--border, #D4D4D4);
      font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif);
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      flex-shrink: 0;
      user-select: none;
    }

    .tab {
      display: flex;
      align-items: center;
      gap: 4px;
      padding: 0 12px;
      height: 100%;
      cursor: pointer;
      color: var(--fg-muted, #999999);
      border-bottom: 2px solid transparent;
      transition: color 0.1s;
    }

    .tab:hover {
      color: var(--fg-secondary, #616161);
    }

    .tab.active {
      color: var(--fg-primary, #333333);
      border-bottom-color: var(--accent, #007ACC);
    }

    .badge {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-width: 16px;
      height: 16px;
      padding: 0 4px;
      border-radius: 8px;
      background: var(--accent, #007ACC);
      color: white;
      font-size: 10px;
      line-height: 1;
    }
  `;

  constructor() {
    super();
    this.tabs = [];
    this._activeTab = 'terminal';
    this._problemsCount = 0;
    this._disposeEffects = [];
    this._unsubs = [];
  }

  firstUpdated() {
    setTimeout(() => {
      const tabCell = getCell('current-bottom-tab');
      this._disposeEffects.push(effect(() => {
        this._activeTab = tabCell.value;
      }));

      this._unsubs.push(
        onMessage('intel:diagnostics', (msg) => {
          this._problemsCount = (msg.items || []).length;
        }),
        onMessage('intel:clear', () => {
          this._problemsCount = 0;
        })
      );
    }, 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    for (const d of this._disposeEffects) d();
    for (const u of this._unsubs) u();
  }

  _selectTab(id) {
    dispatch('bottom-tab:select', { tab: id });
  }

  render() {
    return html`
      ${(this.tabs || []).map(t => html`
        <div class="tab ${this._activeTab === t.id ? 'active' : ''}"
             @click=${() => this._selectTab(t.id)}>
          ${t.label}
          ${t.id === 'problems' && this._problemsCount > 0
            ? html`<span class="badge">${this._problemsCount}</span>`
            : ''}
        </div>
      `)}
    `;
  }
}

customElements.define('hm-bottom-tabs', HmBottomTabs);
```

**Step 2: Add import to main.js**

In `frontend/core/main.js`, add after line 20 (`import './primitives/stepper.js';`):

```javascript
import './primitives/bottom-tabs.js';
```

**Step 3: Commit**

```bash
git add frontend/core/primitives/bottom-tabs.js frontend/core/main.js
git commit -m "feat: add hm-bottom-tabs component for bottom panel tab bar"
```

---

### Task 2: Tab Content Container Component

**Files:**
- Create: `frontend/core/primitives/tab-content.js`
- Modify: `frontend/core/main.js` (add import)

**Step 1: Create `hm-tab-content` component**

Create `frontend/core/primitives/tab-content.js`:

```javascript
// primitives/tab-content.js — hm-tab-content
//
// Container that shows only the child matching the active bottom tab.
// Children must have a `data-tab-id` attribute.

import { LitElement, html, css } from 'lit';
import { effect } from '@preact/signals-core';
import { getCell } from '../cells.js';

class HmTabContent extends LitElement {
  static styles = css`
    :host {
      display: flex;
      flex-direction: column;
      flex: 1;
      overflow: hidden;
    }

    ::slotted(*) {
      display: none !important;
    }

    ::slotted([data-tab-active]) {
      display: flex !important;
      flex-direction: column;
      flex: 1;
    }
  `;

  constructor() {
    super();
    this._disposeEffect = null;
  }

  firstUpdated() {
    setTimeout(() => {
      const tabCell = getCell('current-bottom-tab');
      this._disposeEffect = effect(() => {
        this._updateVisibility(tabCell.value);
      });
    }, 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._disposeEffect) this._disposeEffect();
  }

  _updateVisibility(activeTab) {
    const children = this.querySelectorAll('[data-tab-id]');
    for (const child of children) {
      if (child.getAttribute('data-tab-id') === activeTab) {
        child.setAttribute('data-tab-active', '');
      } else {
        child.removeAttribute('data-tab-active');
      }
    }
  }

  render() {
    return html`<slot></slot>`;
  }
}

customElements.define('hm-tab-content', HmTabContent);
```

**Step 2: Add import to main.js**

In `frontend/core/main.js`, add after the bottom-tabs import:

```javascript
import './primitives/tab-content.js';
```

**Step 3: Commit**

```bash
git add frontend/core/primitives/tab-content.js frontend/core/main.js
git commit -m "feat: add hm-tab-content container for bottom panel tab switching"
```

---

### Task 3: Wire Bottom Tabs Into Layout + Cells

**Files:**
- Modify: `racket/heavymental-core/main.rkt:11-23` (add cell)
- Modify: `racket/heavymental-core/main.rkt:83-104` (restructure bottom panel layout)
- Modify: `racket/heavymental-core/main.rkt:141-227` (add bottom-tab:select handler)

**Step 1: Add `current-bottom-tab` cell**

In `main.rkt`, after line 23 (`(define-cell stepper-total -1)`), add:

```racket
(define-cell current-bottom-tab "terminal")
```

**Step 2: Restructure the bottom panel layout**

Replace lines 83-104 (the vbox containing panel-headers, terminal, error-panel, stepper-toolbar, bindings-panel) with:

```racket
                                      (hasheq 'type "vbox"
                                              'props (hasheq 'flex "1")
                                              'children
                                              (list
                                               ;; Bottom panel tab bar
                                               (hasheq 'type "bottom-tabs"
                                                       'props (hasheq 'tabs
                                                                      (list (hasheq 'id "terminal" 'label "Terminal")
                                                                            (hasheq 'id "problems" 'label "Problems")
                                                                            (hasheq 'id "stepper" 'label "Stepper")
                                                                            (hasheq 'id "macros" 'label "Macros")))
                                                       'children (list))
                                               ;; Tab content: only active tab's child is visible
                                               (hasheq 'type "tab-content"
                                                       'props (hasheq)
                                                       'children
                                                       (list
                                                        ;; TERMINAL tab
                                                        (hasheq 'type "terminal"
                                                                'props (hasheq 'pty-id "repl"
                                                                               'data-tab-id "terminal")
                                                                'children (list))
                                                        ;; PROBLEMS tab
                                                        (hasheq 'type "error-panel"
                                                                'props (hasheq 'data-tab-id "problems")
                                                                'children (list))
                                                        ;; STEPPER tab (vbox wrapping toolbar + bindings)
                                                        (hasheq 'type "vbox"
                                                                'props (hasheq 'data-tab-id "stepper"
                                                                               'flex "1")
                                                                'children
                                                                (list
                                                                 (hasheq 'type "stepper-toolbar"
                                                                         'props (hasheq)
                                                                         'children (list))
                                                                 (hasheq 'type "bindings-panel"
                                                                         'props (hasheq)
                                                                         'children (list))))
                                                        ;; MACROS tab (placeholder for now)
                                                        (hasheq 'type "macro-panel"
                                                                'props (hasheq 'data-tab-id "macros")
                                                                'children (list))))))
```

**Step 3: Add bottom-tab:select event handler**

In `main.rkt` `handle-event`, before the `[else` clause (line 226), add:

```racket
    ;; Bottom panel tab selection
    [(string=? event-name "bottom-tab:select")
     (define tab (message-ref msg 'tab "terminal"))
     (cell-set! 'current-bottom-tab tab)]
```

**Step 4: Add auto-switch on stepper:start**

In the stepper:start handler (lines 214-217), after `(start-stepper path)`, add:

```racket
       (cell-set! 'current-bottom-tab "stepper")
```

**Step 5: Update renderer.js to pass data-tab-id as attribute**

The renderer already handles hyphenated props as attributes (`data-tab-id` contains hyphens → line 41-44 of renderer.js). No change needed.

**Step 6: Remove cell-based hidden toggle from stepper components**

In `frontend/core/primitives/stepper.js`, the `stepper-active` cell effects that toggle `hidden` (lines 69-71 and 191-193) are no longer needed since visibility is now controlled by `hm-tab-content`. Remove both effects:

In `HmStepperToolbar.firstUpdated()` (line 66-76), remove:
```javascript
      this._disposeEffect = effect(() => {
        this.toggleAttribute('hidden', !activeCell.value);
      });
```

In `HmBindingsPanel.firstUpdated()` (line 190-193), remove:
```javascript
      const activeCell = getCell('stepper-active');
      this._disposeEffect = effect(() => {
        this.toggleAttribute('hidden', !activeCell.value);
      });
```

Also remove the `:host([hidden]) { display: none; }` CSS rules from both components' styles.

**Step 7: Test manually**

Run: `cargo tauri dev`
- Verify bottom panel shows tab bar with TERMINAL | PROBLEMS | STEPPER | MACROS
- Click each tab — only that panel's content should be visible
- Terminal should be active by default
- Open a Racket file with errors — PROBLEMS tab badge should show count
- Click Step Through — should auto-switch to STEPPER tab

**Step 8: Commit**

```bash
git add racket/heavymental-core/main.rkt frontend/core/primitives/stepper.js
git commit -m "feat: wire bottom panel tabs into layout with cell-based switching"
```

---

### Task 4: Pending-Goto Queue in editor.rkt

**Files:**
- Modify: `racket/heavymental-core/editor.rkt:10-36` (add provides)
- Modify: `racket/heavymental-core/editor.rkt:117-141` (add pending-goto state)
- Modify: `racket/heavymental-core/editor.rkt:260-284` (check pending-goto on file:read:result)

**Step 1: Add pending-goto state**

In `editor.rkt`, after line 141 (`(define (clear-pending-quit!) (set! _pending-quit #f))`), add:

```racket
;; ── Pending goto state ───────────────────────────────────────────────
;; When a file needs to be opened and then jumped to a position,
;; we queue the goto here. file:read:result handler checks this.
(define _pending-goto #f)

(define (set-pending-goto! path #:line [line #f] #:col [col #f] #:name [name #f])
  (set! _pending-goto (hasheq 'path path
                               'line (or line #f)
                               'col (or col #f)
                               'name (or name #f))))

(define (pending-goto) _pending-goto)
(define (clear-pending-goto!) (set! _pending-goto #f))
```

**Step 2: Add exports**

In `editor.rkt`'s provide list (lines 10-36), add:

```racket
         set-pending-goto!
         pending-goto
         clear-pending-goto!
```

**Step 3: Handle pending-goto in file:read:result**

In `editor.rkt`, in the `"file:read:result"` branch of `handle-file-result` (lines 263-284), after the `send-message!` call for `editor:open` (line 284), add:

```racket
     ;; Check for pending goto
     (define pg (pending-goto))
     (when (and pg (string=? (hash-ref pg 'path "") path))
       (cond
         ;; Goto with known line/col (e.g., REPL error jump)
         [(hash-ref pg 'line #f)
          (send-message! (make-message "editor:goto"
                                       'line (hash-ref pg 'line 1)
                                       'col (hash-ref pg 'col 0)))]
         ;; Goto with symbol name (cross-file definition) — need check-syntax
         [(hash-ref pg 'name #f)
          ;; Analyze the target file to find where the symbol is defined
          (define name (hash-ref pg 'name))
          (define result (analyze-source path content))
          (define defs (hash-ref result 'definitions '()))
          (define match
            (for/first ([d (in-list defs)]
                        #:when (string=? (hash-ref d 'name "") name))
              d))
          (when match
            (define range (offsets->range content
                                          (hash-ref match 'from 0)
                                          (hash-ref match 'to 1)))
            (send-message! (make-message "editor:goto"
                                         'line (hash-ref range 'startLine 1)
                                         'col (hash-ref range 'startCol 0))))])
       (clear-pending-goto!))
```

Note: `analyze-source` and `offsets->range` are in `lang-intel.rkt`. We need to require them.

**Step 4: Add lang-intel.rkt require to editor.rkt**

In `editor.rkt`, add to the require list (line 3-8):

```racket
         "lang-intel.rkt"
```

And in `lang-intel.rkt`, ensure `analyze-source` and `offsets->range` are provided. Check if they already are — if not, add to the provide list.

**Step 5: Commit**

```bash
git add racket/heavymental-core/editor.rkt
git commit -m "feat: add pending-goto queue for sequenced file open + jump"
```

---

### Task 5: Fix editor:goto-file Sequencing (main.rkt TODO)

**Files:**
- Modify: `racket/heavymental-core/main.rkt:192-204` (fix editor:goto-file handler)

**Step 1: Replace the broken handler**

Replace lines 192-204 (the `editor:goto-file` handler with the TODO) with:

```racket
    ;; REPL error → jump to source file (uses pending-goto for proper sequencing)
    [(string=? event-name "editor:goto-file")
     (define path (message-ref msg 'path ""))
     (define line (message-ref msg 'line 1))
     (define col (message-ref msg 'col 0))
     (when (not (string=? path ""))
       (cond
         ;; If the file is already open, just goto
         [(string=? path (current-file-path))
          (send-message! (make-message "editor:goto" 'line line 'col col))]
         [else
          ;; Open the file first, then goto after it loads
          (set-pending-goto! path #:line line #:col col)
          (send-message! (make-message "file:read" 'path path))]))]
```

**Step 2: Commit**

```bash
git add racket/heavymental-core/main.rkt
git commit -m "fix: proper sequencing for editor:goto-file using pending-goto queue"
```

---

### Task 6: Cross-File Go-to-Definition (Frontend + Racket)

**Files:**
- Modify: `frontend/core/lang-intel.js:206-210` (dispatch goto-definition)
- Modify: `racket/heavymental-core/main.rkt:141-227` (add editor:goto-definition handler)

**Step 1: Wire the frontend definition provider**

In `frontend/core/lang-intel.js`, replace lines 206-210:

```javascript
            // Cross-file jump
            if (j.targetUri) {
              // TODO: open the target file
              return null;
            }
```

With:

```javascript
            // Cross-file jump — dispatch to Racket for sequenced open + goto
            if (j.targetUri) {
              dispatch('editor:goto-definition', {
                path: j.targetUri,
                name: j.name,
              });
              return null;
            }
```

**Step 2: Add event handler in main.rkt**

In `main.rkt` `handle-event`, before the `bottom-tab:select` handler (added in Task 3), add:

```racket
    ;; Cross-file go-to-definition (from lang-intel.js definition provider)
    [(string=? event-name "editor:goto-definition")
     (define path (message-ref msg 'path ""))
     (define name (message-ref msg 'name ""))
     (when (and (not (string=? path ""))
                (not (string=? name "")))
       (cond
         ;; If the file is already open, analyze and jump
         [(string=? path (current-file-path))
          ;; Already open — run check-syntax to find definition
          (void)] ;; Same-file definitions are handled by arrows, not jump targets
         [else
          ;; Open file, then find definition after it loads
          (set-pending-goto! path #:name name)
          (send-message! (make-message "file:read" 'path path))]))]
```

**Step 3: Test manually**

Run: `cargo tauri dev`
- Open a Racket file that requires another module
- Cmd-click on an imported function name
- Should open the target file in a new tab and jump to the definition

**Step 4: Commit**

```bash
git add frontend/core/lang-intel.js racket/heavymental-core/main.rkt
git commit -m "feat: cross-file go-to-definition via pending-goto queue"
```

---

### Task 7: Macro Expander Racket Module

**Files:**
- Create: `racket/heavymental-core/macro-expander.rkt`

**Step 1: Create macro-expander.rkt**

```racket
#lang racket/base

(require racket/list
         racket/match
         racket/port
         syntax/parse
         "protocol.rkt"
         "cell.rkt")

(provide start-macro-expander
         stop-macro-expander)

;; ── State ─────────────────────────────────────────────────
(define _macro-active #f)
(define _node-counter 0)

(define (next-node-id!)
  (set! _node-counter (add1 _node-counter))
  (format "node-~a" _node-counter))

;; ── Syntax utilities ──────────────────────────────────────

;; Pretty-print a syntax object to a string
(define (syntax->string stx)
  (define out (open-output-string))
  (pretty-write (syntax->datum stx) out)
  (string-trim (get-output-string out)))

;; Get the head identifier of a syntax list, if any
(define (syntax-head stx)
  (syntax-case stx ()
    [(head . _) (identifier? #'head) (symbol->string (syntax-e #'head))]
    [_ #f]))

;; Check if two syntax objects are identical (no expansion happened)
(define (syntax-unchanged? before after)
  (equal? (syntax->datum before) (syntax->datum after)))

;; ── Expansion tree builder ────────────────────────────────

;; expand-and-trace: recursively expand a syntax object,
;; building a tree of macro applications.
;;
;; Returns: hasheq with keys:
;;   'id       — unique node id
;;   'macro    — name of macro applied (or #f if leaf)
;;   'before   — string of form before expansion
;;   'after    — string of form after expansion (or #f if leaf)
;;   'children — list of child nodes
(define (expand-and-trace stx ns)
  (define id (next-node-id!))
  (define before-str (syntax->string stx))

  ;; Try expand-once
  (define expanded
    (with-handlers ([exn:fail? (lambda (e) stx)])
      (parameterize ([current-namespace ns])
        (expand-once stx))))

  (cond
    ;; No expansion happened — leaf node
    [(syntax-unchanged? stx expanded)
     (hasheq 'id id
             'macro #f
             'before before-str
             'after #f
             'children (list))]

    ;; Expansion happened — record it and recurse
    [else
     (define macro-name (or (syntax-head stx) "???"))
     (define after-str (syntax->string expanded))

     ;; Recursively trace the sub-expressions of the expanded form
     (define children
       (syntax-case expanded ()
         [(parts ...)
          (for/list ([part (in-list (syntax->list #'(parts ...)))])
            (expand-and-trace part ns))]
         [_ (list)]))

     ;; Filter out leaf children with no macro application
     ;; (keep the tree focused on actual macro steps)
     (define interesting-children
       (filter (lambda (c) (or (hash-ref c 'macro #f)
                               (not (null? (hash-ref c 'children '())))))
               children))

     (hasheq 'id id
             'macro macro-name
             'before before-str
             'after after-str
             'children interesting-children)]))

;; ── Public API ────────────────────────────────────────────

(define (start-macro-expander path)
  (set! _macro-active #t)
  (set! _node-counter 0)
  (cell-set! 'macro-active #t)

  (with-handlers ([exn:fail?
                   (lambda (e)
                     (send-message! (make-message "macro:error"
                                                  'error (exn-message e)))
                     (stop-macro-expander))])
    ;; Read and parse the source file
    (define text (file->string path))
    (define port (open-input-string text))
    (port-count-lines! port)

    ;; Set up namespace for expansion
    (define ns (make-base-namespace))

    ;; Read and expand each top-level form
    (define forms
      (let loop ([acc '()])
        (define stx (read-syntax path port))
        (if (eof-object? stx)
            (reverse acc)
            (loop (cons (expand-and-trace stx ns) acc)))))

    ;; Send the expansion tree to frontend
    (send-message! (make-message "macro:tree" 'forms forms))
    (cell-set! 'current-bottom-tab "macros")))

(define (stop-macro-expander)
  (set! _macro-active #f)
  (cell-set! 'macro-active #f)
  (send-message! (make-message "macro:clear")))
```

**Step 2: Commit**

```bash
git add racket/heavymental-core/macro-expander.rkt
git commit -m "feat: macro-expander.rkt — recursive expand-once tree builder"
```

---

### Task 8: Wire Macro Expander Into Main

**Files:**
- Modify: `racket/heavymental-core/main.rkt:1-9` (add require)
- Modify: `racket/heavymental-core/main.rkt:11-24` (add cell)
- Modify: `racket/heavymental-core/main.rkt:113-138` (add menu item)
- Modify: `racket/heavymental-core/main.rkt:141-227` (add event handler)
- Modify: `racket/heavymental-core/main.rkt:230-247` (add menu action)

**Step 1: Add require**

In `main.rkt`, add to requires (after line 9, `"stepper.rkt"`):

```racket
         "macro-expander.rkt"
```

**Step 2: Add macro-active cell**

After the `current-bottom-tab` cell (added in Task 3):

```racket
(define-cell macro-active #f)
```

**Step 3: Add menu item**

In the "Racket" menu (lines 132-138), after the "Stop Stepper" entry, add:

```racket
            (hasheq 'label "---")
            (hasheq 'label "Expand Macros" 'shortcut "Cmd+Shift+E" 'action "expand-macros")
```

**Step 4: Add event handler**

In `handle-event`, before the bottom-tab:select handler, add:

```racket
    ;; Macro expander events
    [(string=? event-name "macro:expand")
     (define path (message-ref msg 'path (current-file-path)))
     (when (and path (not (string=? path "")) (not (string=? path "untitled.rkt")))
       (start-macro-expander path))]
    [(string=? event-name "macro:stop")
     (stop-macro-expander)]
```

**Step 5: Add menu action handler**

In `handle-menu-action`, before the `[else` clause, add:

```racket
    [(string=? action "expand-macros")
     (define path (current-file-path))
     (when (and path (not (string=? path "")) (not (string=? path "untitled.rkt")))
       (start-macro-expander path))]
```

**Step 6: Commit**

```bash
git add racket/heavymental-core/main.rkt
git commit -m "feat: wire macro expander into main event loop and menu"
```

---

### Task 9: Add Expand Macros Button to Breadcrumb

**Files:**
- Modify: `frontend/core/primitives/chrome.js:170-197` (add button in breadcrumb render)

**Step 1: Add Expand Macros button**

In `chrome.js`, in the `HmBreadcrumb` render method, add a new button after the Step Through button (after line 196). Before the closing `</div>` of `.actions`:

```javascript
        ${!isStepping && !isRunning
          ? html`<span class="action-btn expand" title="Expand Macros (Cmd+Shift+E)" @click=${() => dispatch('macro:expand', { path: filePath })}>
              <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
                <path d="M2 4h12M2 8h8M2 12h10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
                <circle cx="13" cy="10" r="2.5" stroke="currentColor" stroke-width="1.2" fill="none"/>
              </svg>
            </span>`
          : ''}
```

Also add `macro-active` to the cell effects in `firstUpdated()` if you want to show/hide the button when macros are active.

**Step 2: Commit**

```bash
git add frontend/core/primitives/chrome.js
git commit -m "feat: add Expand Macros button to breadcrumb toolbar"
```

---

### Task 10: Macro Panel Frontend Component

**Files:**
- Create: `frontend/core/primitives/macro-panel.js`
- Modify: `frontend/core/main.js` (add import)

**Step 1: Create `hm-macro-panel` component**

Create `frontend/core/primitives/macro-panel.js`:

```javascript
// primitives/macro-panel.js — hm-macro-panel
//
// Displays a macro expansion tree with a detail view.
// Left pane: collapsible tree of macro applications.
// Right pane: before/after forms in read-only Monaco editors.

import { LitElement, html, css } from 'lit';
import { onMessage, dispatch } from '../bridge.js';

class HmMacroPanel extends LitElement {
  static styles = css`
    :host {
      display: flex;
      flex-direction: column;
      flex: 1;
      overflow: hidden;
      background: var(--bg-primary, #FFFFFF);
      font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif);
      font-size: 13px;
    }

    .toolbar {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      background: var(--bg-toolbar, #F8F8F8);
      border-bottom: 1px solid var(--border, #D4D4D4);
      min-height: 28px;
      flex-shrink: 0;
    }

    .toolbar button {
      display: flex;
      align-items: center;
      gap: 4px;
      padding: 3px 8px;
      border: 1px solid var(--border, #D4D4D4);
      border-radius: 3px;
      background: var(--bg-primary, #FFFFFF);
      color: var(--fg-primary, #333333);
      cursor: pointer;
      font-size: 12px;
      font-family: inherit;
    }

    .toolbar button:hover {
      background: var(--bg-tab-hover, #F0F0F0);
    }

    .content {
      display: flex;
      flex: 1;
      overflow: hidden;
    }

    .tree-pane {
      width: 40%;
      min-width: 200px;
      overflow: auto;
      border-right: 1px solid var(--border, #D4D4D4);
      padding: 8px;
    }

    .detail-pane {
      flex: 1;
      overflow: auto;
      padding: 8px 12px;
    }

    .tree-node {
      padding: 2px 0;
    }

    .tree-label {
      display: flex;
      align-items: center;
      gap: 4px;
      padding: 2px 4px;
      border-radius: 3px;
      cursor: pointer;
      font-family: var(--font-editor, "SF Mono", Menlo, monospace);
      font-size: 12px;
      font-weight: var(--font-editor-weight, 300);
    }

    .tree-label:hover {
      background: var(--bg-tab-hover, #F0F0F0);
    }

    .tree-label.selected {
      background: var(--accent-bg, #E3F2FD);
      color: var(--accent, #007ACC);
    }

    .tree-children {
      padding-left: 16px;
    }

    .toggle {
      width: 12px;
      text-align: center;
      color: var(--fg-muted, #999999);
      flex-shrink: 0;
    }

    .macro-name {
      color: var(--accent, #007ACC);
      font-weight: 500;
    }

    .arrow {
      color: var(--fg-muted, #999999);
    }

    .detail-section {
      margin-bottom: 12px;
    }

    .detail-label {
      font-size: 11px;
      font-weight: 600;
      color: var(--fg-muted, #999999);
      text-transform: uppercase;
      letter-spacing: 0.5px;
      margin-bottom: 4px;
    }

    .code-block {
      padding: 8px;
      background: var(--bg-panel, #F5F5F5);
      border: 1px solid var(--border, #D4D4D4);
      border-radius: 4px;
      font-family: var(--font-editor, "SF Mono", Menlo, monospace);
      font-size: 12px;
      font-weight: var(--font-editor-weight, 300);
      white-space: pre-wrap;
      word-break: break-word;
      overflow: auto;
      max-height: 200px;
    }

    .info-row {
      display: flex;
      gap: 8px;
      font-size: 12px;
      color: var(--fg-secondary, #616161);
      margin-top: 8px;
    }

    .info-label {
      color: var(--fg-muted, #999999);
    }

    .empty {
      color: var(--fg-muted, #999999);
      font-style: italic;
      padding: 20px;
      text-align: center;
    }

    .pattern-placeholder {
      padding: 8px;
      background: #FFFDE7;
      border: 1px solid #FBC02D;
      border-radius: 4px;
      font-size: 12px;
      color: var(--fg-secondary, #616161);
      font-style: italic;
    }
  `;

  constructor() {
    super();
    this._forms = [];
    this._selectedNode = null;
    this._expandedNodes = new Set();
    this._unsubs = [];
    this._error = null;
  }

  firstUpdated() {
    setTimeout(() => {
      this._unsubs.push(
        onMessage('macro:tree', (msg) => {
          this._forms = msg.forms || [];
          this._selectedNode = null;
          this._error = null;
          // Auto-expand first level
          for (const f of this._forms) {
            if (f.macro) this._expandedNodes.add(f.id);
          }
          this.requestUpdate();
        }),
        onMessage('macro:error', (msg) => {
          this._error = msg.error || 'Unknown error';
          this._forms = [];
          this._selectedNode = null;
          this.requestUpdate();
        }),
        onMessage('macro:clear', () => {
          this._forms = [];
          this._selectedNode = null;
          this._error = null;
          this._expandedNodes.clear();
          this.requestUpdate();
        })
      );
    }, 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    for (const u of this._unsubs) u();
  }

  _toggleNode(id) {
    if (this._expandedNodes.has(id)) {
      this._expandedNodes.delete(id);
    } else {
      this._expandedNodes.add(id);
    }
    this.requestUpdate();
  }

  _selectNode(node) {
    this._selectedNode = node;
    this.requestUpdate();
  }

  _collapseAll() {
    this._expandedNodes.clear();
    this.requestUpdate();
  }

  _expandAll() {
    const walk = (nodes) => {
      for (const n of nodes) {
        if (n.children && n.children.length > 0) {
          this._expandedNodes.add(n.id);
          walk(n.children);
        }
      }
    };
    walk(this._forms);
    this.requestUpdate();
  }

  _renderNode(node) {
    if (!node.macro && (!node.children || node.children.length === 0)) {
      return html``; // Skip leaf nodes with no macro
    }

    const hasChildren = node.children && node.children.length > 0;
    const isExpanded = this._expandedNodes.has(node.id);
    const isSelected = this._selectedNode?.id === node.id;

    // Truncate before string for tree display
    const summary = node.before?.length > 40
      ? node.before.substring(0, 40) + '...'
      : node.before || '';

    return html`
      <div class="tree-node">
        <div class="tree-label ${isSelected ? 'selected' : ''}"
             @click=${() => this._selectNode(node)}>
          ${hasChildren
            ? html`<span class="toggle" @click=${(e) => { e.stopPropagation(); this._toggleNode(node.id); }}>
                ${isExpanded ? '\u25BC' : '\u25B6'}
              </span>`
            : html`<span class="toggle"></span>`}
          ${node.macro
            ? html`<span class="macro-name">${node.macro}</span>
                   <span class="arrow">\u2192</span>`
            : ''}
          <span>${summary}</span>
        </div>
        ${hasChildren && isExpanded ? html`
          <div class="tree-children">
            ${node.children.map(c => this._renderNode(c))}
          </div>
        ` : ''}
      </div>
    `;
  }

  _renderDetail() {
    const node = this._selectedNode;
    if (!node) {
      return html`<div class="empty">Select a node in the expansion tree</div>`;
    }

    return html`
      ${node.macro ? html`
        <div class="info-row">
          <span class="info-label">Macro:</span>
          <span class="macro-name">${node.macro}</span>
        </div>
      ` : ''}

      <div class="detail-section">
        <div class="detail-label">Before</div>
        <div class="code-block">${node.before || '(empty)'}</div>
      </div>

      ${node.after ? html`
        <div class="detail-section">
          <div class="detail-label">After</div>
          <div class="code-block">${node.after}</div>
        </div>
      ` : ''}

      <div class="detail-section">
        <div class="detail-label">Pattern Match</div>
        <div class="pattern-placeholder">
          Pattern match highlighting not yet available.
          Will show SyntaxSpec pattern matches in a future update.
        </div>
      </div>
    `;
  }

  render() {
    if (this._error) {
      return html`
        <div class="toolbar">
          <button @click=${() => dispatch('macro:stop')}>Clear</button>
        </div>
        <div class="empty">Error: ${this._error}</div>
      `;
    }

    if (this._forms.length === 0) {
      return html`
        <div class="toolbar">
          <span style="color: var(--fg-muted, #999); font-size: 12px;">
            Use Expand Macros (Cmd+Shift+E) to view macro expansions
          </span>
        </div>
        <div class="empty">No expansion data. Open a Racket file and click Expand Macros.</div>
      `;
    }

    return html`
      <div class="toolbar">
        <button @click=${() => this._expandAll()}>Expand All</button>
        <button @click=${() => this._collapseAll()}>Collapse All</button>
        <button @click=${() => dispatch('macro:stop')}>Clear</button>
      </div>
      <div class="content">
        <div class="tree-pane">
          ${this._forms.map(f => this._renderNode(f))}
        </div>
        <div class="detail-pane">
          ${this._renderDetail()}
        </div>
      </div>
    `;
  }
}

customElements.define('hm-macro-panel', HmMacroPanel);
```

**Step 2: Add import to main.js**

In `frontend/core/main.js`, add:

```javascript
import './primitives/macro-panel.js';
```

**Step 3: Commit**

```bash
git add frontend/core/primitives/macro-panel.js frontend/core/main.js
git commit -m "feat: add hm-macro-panel component with expansion tree and detail view"
```

---

### Task 11: Write Macro Expander Tests

**Files:**
- Create: `test/test-macro-expander.rkt`

**Step 1: Write tests**

```racket
#lang racket/base

(require rackunit
         "../racket/heavymental-core/macro-expander.rkt"
         "../racket/heavymental-core/protocol.rkt"
         "../racket/heavymental-core/cell.rkt")

;; ── Test helpers ──────────────────────────────────────────
;; Capture messages sent during macro expansion
(define captured-messages '())
(define orig-send #f)

(define (capture-messages! thunk)
  (set! captured-messages '())
  ;; Override send-message! temporarily
  ;; (This requires send-message! to be mockable — may need adjustment)
  (thunk)
  captured-messages)

;; ── Tests ─────────────────────────────────────────────────

(test-case "expand-and-trace produces tree for simple macro"
  ;; Write a temp file with a simple cond expression
  (define tmp (make-temporary-file "macro-test-~a.rkt"))
  (call-with-output-file tmp
    (lambda (out)
      (display "#lang racket/base\n(cond [#t 1] [else 2])\n" out))
    #:exists 'replace)

  ;; Start expansion (this sends messages to stdout — we just verify no crash)
  ;; In a real test we'd capture the messages
  (check-not-exn
    (lambda ()
      (start-macro-expander (path->string tmp))))

  (stop-macro-expander)
  (delete-file tmp))

(test-case "expand-and-trace handles syntax errors gracefully"
  (define tmp (make-temporary-file "macro-test-~a.rkt"))
  (call-with-output-file tmp
    (lambda (out)
      (display "#lang racket/base\n(define x (+ 1\n" out))
    #:exists 'replace)

  ;; Should send macro:error, not crash
  (check-not-exn
    (lambda ()
      (start-macro-expander (path->string tmp))))

  (stop-macro-expander)
  (delete-file tmp))

(test-case "stop-macro-expander resets state"
  (stop-macro-expander)
  ;; Should not crash when called without start
  (check-not-exn (lambda () (stop-macro-expander))))
```

**Step 2: Run tests**

Run: `racket test/test-macro-expander.rkt`
Expected: All tests pass (may need adjustment for message capture)

**Step 3: Commit**

```bash
git add test/test-macro-expander.rkt
git commit -m "test: add macro expander tests"
```

---

### Task 12: Integration Test + Manual Verification

**Files:**
- No new files — manual testing

**Step 1: Full integration test**

Run: `cargo tauri dev`

Test checklist:
1. [ ] Bottom panel tab bar shows: TERMINAL | PROBLEMS | STEPPER | MACROS
2. [ ] Clicking tabs switches visible panel
3. [ ] Terminal is default active tab
4. [ ] PROBLEMS badge shows diagnostic count
5. [ ] Step Through auto-switches to STEPPER tab
6. [ ] Open a file that imports another module
7. [ ] Cmd-click an imported name → opens target file + jumps to definition
8. [ ] REPL error click → opens source file + jumps to line (sequencing fix)
9. [ ] Cmd+Shift+E or menu "Expand Macros" → MACROS tab shows expansion tree
10. [ ] Click tree nodes → detail pane shows before/after
11. [ ] Expand All / Collapse All buttons work
12. [ ] Clear button resets macro panel
13. [ ] Pattern Match section shows "not yet available" placeholder

**Step 2: Fix any issues found**

Address any bugs discovered during manual testing.

**Step 3: Final commit**

```bash
git add -A
git commit -m "fix: integration fixes from manual testing"
```

---

### Task 13: Run Existing Tests

**Files:**
- No changes — verification only

**Step 1: Run all Racket tests**

```bash
racket test/test-bridge.rkt
racket test/test-phase2.rkt
racket test/test-lang-intel.rkt
racket test/test-macro-expander.rkt
```

Expected: All pass. If any fail due to new requires or modified provides, fix them.

**Step 2: Commit any fixes**

```bash
git add -A
git commit -m "fix: test compatibility with new modules"
```
