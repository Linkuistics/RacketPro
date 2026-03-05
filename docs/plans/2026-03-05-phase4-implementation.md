# Phase 4 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make HeavyMental usable end-to-end (open, edit, save, run) with proper dirty state tracking, file tree sync, tab management, and a basic expression stepper with bindings display.

**Architecture:** Racket owns all state (dirty files, stepper state). Rust intercepts dialog messages and provides native OS dialogs. Frontend remains a pure rendering surface consuming cells and bridge messages. The stepper uses Racket's `stepper/private/model` `go` function with a custom `receive-result` callback that serializes `Before-After-Result` structs into JSON messages.

**Tech Stack:** Racket (state + stepper), Rust/Tauri (dialog plugin, bridge), Lit Web Components + signals (frontend rendering), Playwright (E2E tests), rackunit (Racket tests).

**Design doc:** `docs/plans/2026-03-05-phase4-usability-stepper-design.md`

---

## Task 1: Dirty State Infrastructure (Racket)

Track which files have unsaved changes. Racket owns this state via a `dirty-files` cell.

**Files:**
- Modify: `racket/heavymental-core/editor.rkt` (add dirty set, update handlers)
- Modify: `racket/heavymental-core/main.rkt` (add `dirty-files` cell, wire events)
- Test: `test/test-phase4.rkt` (new file)

**Step 1: Write the failing test**

Create `test/test-phase4.rkt`:

```racket
#lang racket/base

(require rackunit
         json
         racket/port
         racket/string
         racket/set
         "../racket/heavymental-core/protocol.rkt"
         "../racket/heavymental-core/cell.rkt"
         "../racket/heavymental-core/editor.rkt")

;; ── Helpers ──────────────────────────────────────────────────────────────────

(define (parse-all-messages output)
  (define lines (string-split (string-trim output) "\n"))
  (for/list ([line (in-list lines)]
             #:when (> (string-length (string-trim line)) 0))
    (string->jsexpr line)))

;; Cells needed by editor.rkt
(define-cell current-file "untitled.rkt")
(define-cell file-dirty #f)
(define-cell title "HeavyMental")
(define-cell status "starting")
(define-cell dirty-files (list))

(define (reset-cells!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "untitled.rkt")
      (cell-set! 'file-dirty #f)
      (cell-set! 'title "HeavyMental")
      (cell-set! 'status "starting")
      (cell-set! 'dirty-files (list)))))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: dirty-files tracking
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "mark-file-dirty! adds path to dirty-files"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (mark-file-dirty! "/tmp/foo.rkt")))
  (check-true (file-dirty? "/tmp/foo.rkt")))

(test-case "mark-file-clean! removes path from dirty-files"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (mark-file-dirty! "/tmp/foo.rkt")
      (mark-file-clean! "/tmp/foo.rkt")))
  (check-false (file-dirty? "/tmp/foo.rkt")))

(test-case "multiple dirty files tracked independently"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (mark-file-dirty! "/tmp/a.rkt")
      (mark-file-dirty! "/tmp/b.rkt")
      (mark-file-clean! "/tmp/a.rkt")))
  (check-false (file-dirty? "/tmp/a.rkt"))
  (check-true (file-dirty? "/tmp/b.rkt")))

(test-case "any-dirty-files? returns #t when dirty files exist"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (mark-file-dirty! "/tmp/foo.rkt")))
  (check-true (any-dirty-files?)))

(test-case "any-dirty-files? returns #f when no dirty files"
  (reset-cells!)
  (check-false (any-dirty-files?)))

(test-case "editor:dirty event marks file dirty and updates cell"
  (reset-cells!)
  (define output
    (with-output-to-string
      (lambda ()
        (handle-editor-event
         (make-message "event" 'name "editor:dirty" 'path "/tmp/test.rkt")))))
  (define msgs (parse-all-messages output))
  ;; Should have cell:update for dirty-files
  (check-true
   (ormap (lambda (m)
            (and (equal? (hash-ref m 'type #f) "cell:update")
                 (equal? (hash-ref m 'name #f) "dirty-files")))
          msgs))
  (check-true (file-dirty? "/tmp/test.rkt")))

(test-case "file:write:result clears dirty state"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "/tmp/test.rkt")
      (mark-file-dirty! "/tmp/test.rkt")))
  (check-true (file-dirty? "/tmp/test.rkt"))
  (with-output-to-string
    (lambda ()
      (handle-file-result
       (make-message "file:write:result" 'path "/tmp/test.rkt"))))
  (check-false (file-dirty? "/tmp/test.rkt")))
```

**Step 2: Run test to verify it fails**

Run: `racket test/test-phase4.rkt`
Expected: FAIL — `mark-file-dirty!`, `mark-file-clean!`, `file-dirty?`, `any-dirty-files?` not yet exported from `editor.rkt`.

**Step 3: Implement dirty state in editor.rkt**

Add to `editor.rkt`:

1. Add `racket/set` to requires.
2. Add to provide list: `mark-file-dirty!`, `mark-file-clean!`, `file-dirty?`, `any-dirty-files?`.
3. Add internal mutable set and functions:

```racket
;; ── Dirty file tracking ─────────────────────────────────────────────
;; Mutable set of file paths with unsaved changes.
;; The dirty-files cell is maintained as a JSON-friendly list.
(define dirty-set (mutable-set))

(define (mark-file-dirty! path)
  (set-add! dirty-set path)
  (sync-dirty-cell!))

(define (mark-file-clean! path)
  (set-remove! dirty-set path)
  (sync-dirty-cell!))

(define (file-dirty? path)
  (set-member? dirty-set path))

(define (any-dirty-files?)
  (positive? (set-count dirty-set)))

(define (sync-dirty-cell!)
  (cell-set! 'dirty-files (set->list dirty-set)))
```

4. In `handle-editor-event`, update the `"editor:dirty"` branch to also call `mark-file-dirty!`:

```racket
["editor:dirty"
 (define path (message-ref msg 'path (current-file-path)))
 (mark-file-dirty! path)
 (cell-set! 'file-dirty #t)
 ;; Update title to show dirty indicator
 (define filename (path->filename (current-file-path)))
 (cell-set! 'title (format "HeavyMental — ~a *" filename))]
```

5. In `handle-file-result`, at the end of the `"file:write:result"` branch, add:

```racket
(mark-file-clean! path)
```

**Step 4: Add dirty-files cell to main.rkt**

In `main.rkt`, add after the existing cell definitions:

```racket
(define-cell dirty-files (list))
```

**Step 5: Run test to verify it passes**

Run: `racket test/test-phase4.rkt`
Expected: All 7 tests PASS.

**Step 6: Run existing tests to verify no regressions**

Run: `racket test/test-phase2.rkt && racket test/test-bridge.rkt && racket test/test-lang-intel.rkt`
Expected: All existing tests still pass.

**Step 7: Commit**

```bash
git add racket/heavymental-core/editor.rkt racket/heavymental-core/main.rkt test/test-phase4.rkt
git commit -m "feat: dirty-files tracking in Racket with cell sync"
```

---

## Task 2: Tab Dirty Indicators (Frontend)

Show `•` dot on tabs with unsaved changes.

**Files:**
- Modify: `frontend/core/primitives/tabs.js` (read dirty-files cell, render dot)
- Modify: `test/e2e/fixtures.js` (add dirty-files cell to CELLS)
- Test: `test/e2e/phase4.spec.js` (new file)

**Step 1: Write the failing E2E test**

Create `test/e2e/phase4.spec.js`:

```javascript
// @ts-check
import { test, expect } from '@playwright/test';
import {
  bootApp,
  sendBootMessages,
  waitForMonaco,
  fireEvent,
  getInvocations,
  clearInvocations,
} from './fixtures.js';

// ── Group 1: Dirty State ─────────────────────────────────────────────

test.describe('Dirty state indicators', () => {
  test.beforeEach(async ({ page }) => {
    await bootApp(page);
    await sendBootMessages(page);
    await waitForMonaco(page);
  });

  test('tab shows dirty dot when file is in dirty-files cell', async ({ page }) => {
    // Open a file (creates a tab)
    await fireEvent(page, 'editor:open', {
      path: '/tmp/test.rkt',
      content: '#lang racket\n',
      language: 'racket',
    });

    // Verify tab exists without dot
    const tab = page.locator('hm-tabs').locator('.tab');
    await expect(tab).toContainText('test.rkt');
    const textBefore = await tab.locator('.tab-label').textContent();
    expect(textBefore).not.toContain('•');

    // Update dirty-files cell to include this file
    await fireEvent(page, 'cell:update', {
      name: 'dirty-files',
      value: ['/tmp/test.rkt'],
    });

    // Wait for reactivity
    await page.waitForTimeout(100);

    // Tab should now show dirty dot
    const textAfter = await tab.locator('.tab-label').textContent();
    expect(textAfter).toContain('•');
  });

  test('dirty dot disappears when file is saved', async ({ page }) => {
    // Open file and mark dirty
    await fireEvent(page, 'editor:open', {
      path: '/tmp/test.rkt',
      content: '#lang racket\n',
      language: 'racket',
    });
    await fireEvent(page, 'cell:update', {
      name: 'dirty-files',
      value: ['/tmp/test.rkt'],
    });
    await page.waitForTimeout(100);

    // Verify dot is present
    const tab = page.locator('hm-tabs').locator('.tab');
    let text = await tab.locator('.tab-label').textContent();
    expect(text).toContain('•');

    // Clear dirty-files (simulating save)
    await fireEvent(page, 'cell:update', {
      name: 'dirty-files',
      value: [],
    });
    await page.waitForTimeout(100);

    // Dot should be gone
    text = await tab.locator('.tab-label').textContent();
    expect(text).not.toContain('•');
  });
});
```

**Step 2: Add dirty-files cell to test fixtures**

In `test/e2e/fixtures.js`, add to the `CELLS` array:

```javascript
{ name: 'dirty-files', value: [] },
```

**Step 3: Run test to verify it fails**

Run: `cd test/e2e && npx playwright test phase4.spec.js --reporter=list`
Expected: FAIL — tabs don't show dirty dots yet.

**Step 4: Implement dirty dot in hm-tabs**

In `frontend/core/primitives/tabs.js`:

1. Add `getCell` import: `import { getCell } from '../cells.js';`
2. In `firstUpdated()`, add an effect watching dirty-files cell (inside the existing `setTimeout`):

```javascript
// Watch dirty-files cell for dirty indicators
const dirtyCell = getCell('dirty-files');
this._disposeDirty = effect(() => {
  this._dirtyPaths = new Set(dirtyCell.value || []);
  this.requestUpdate();
});
```

3. Add `_dirtyPaths` initialization in constructor: `this._dirtyPaths = new Set();`
4. Add cleanup in `disconnectedCallback()`: dispose `_disposeDirty`.
5. In `render()`, update the tab label to show dot:

```javascript
const isDirty = this._dirtyPaths.has(tab.path);
// In the template:
<span class="tab-label">${isDirty ? '• ' : ''}${tab.name}</span>
```

**Step 5: Run test to verify it passes**

Run: `cd test/e2e && npx playwright test phase4.spec.js --reporter=list`
Expected: Both dirty state tests PASS.

**Step 6: Commit**

```bash
git add frontend/core/primitives/tabs.js test/e2e/phase4.spec.js test/e2e/fixtures.js
git commit -m "feat: dirty dot indicator on tabs via dirty-files cell"
```

---

## Task 3: Dialog Infrastructure (Rust)

Add `dialog:confirm` message handling in the Rust bridge so Racket can show native 3-button dialogs (Save / Don't Save / Cancel).

**Files:**
- Modify: `src-tauri/src/bridge.rs` (add `dialog:confirm` interceptor)

**Step 1: Implement dialog:confirm handler in bridge.rs**

Add a new arm in `handle_intercepted_message` in `bridge.rs`, before the `_ => false` catch-all:

```rust
// ----- Dialogs ---------------------------------------------------
"dialog:confirm" => {
    let id = msg.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let title = msg.get("title").and_then(|v| v.as_str()).unwrap_or("Confirm").to_string();
    let message = msg.get("message").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let save_label = msg.get("save_label").and_then(|v| v.as_str()).unwrap_or("Save").to_string();
    let dont_save_label = msg.get("dont_save_label").and_then(|v| v.as_str()).unwrap_or("Don't Save").to_string();
    let tx = tx.clone();
    let app = app.clone();
    thread::spawn(move || {
        // Use Tauri's message dialog with Yes/No + custom message.
        // Map: Yes → "save", No → "dont-save", window close → "cancel"
        use tauri_plugin_dialog::MessageDialogButtons;
        let result = app.dialog()
            .message(&message)
            .title(&title)
            .buttons(MessageDialogButtons::OkCancelCustom(
                save_label.clone(),
                dont_save_label.clone(),
            ))
            .blocking_show();
        let choice = if result { "save" } else { "dont-save" };
        let _ = tx.send(serde_json::json!({
            "type": "dialog:confirm:result",
            "id": id,
            "choice": choice,
        }));
    });
    true
}
```

Note: Tauri's dialog plugin `OkCancelCustom` returns `true` for the first button and `false` for the second. We map this to "save" / "dont-save". A true "cancel" (closing the dialog window) also returns `false`, which we treat as "dont-save" for simplicity in v1. If users want a 3-way dialog later, we can use a custom webview dialog.

**Step 2: Verify Rust compiles**

Run: `cd src-tauri && cargo check`
Expected: Compiles without errors.

**Step 3: Commit**

```bash
git add src-tauri/src/bridge.rs
git commit -m "feat: dialog:confirm message handling in Rust bridge"
```

---

## Task 4: Tab Close with Dirty Check (Racket + Frontend)

When closing a dirty tab, show a native dialog asking to save first.

**Files:**
- Modify: `racket/heavymental-core/main.rkt` (handle tab:close-request, dialog:confirm:result)
- Modify: `frontend/core/primitives/tabs.js` (dispatch tab:close-request, listen for tab:close)
- Test: `test/test-phase4.rkt` (add close-request tests)
- Test: `test/e2e/phase4.spec.js` (add close tests)

**Step 1: Write failing Racket test**

Add to `test/test-phase4.rkt`:

```racket
;; ═══════════════════════════════════════════════════════════════════════════
;; Test: tab close request handling
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "tab:close-request for clean file sends tab:close immediately"
  (reset-cells!)
  (define output
    (with-output-to-string
      (lambda ()
        (handle-event
         (make-message "event" 'name "tab:close-request" 'path "/tmp/clean.rkt")))))
  (define msgs (parse-all-messages output))
  ;; Should send tab:close directly (no dialog needed)
  (check-true
   (ormap (lambda (m)
            (and (equal? (hash-ref m 'type #f) "tab:close")
                 (equal? (hash-ref m 'path #f) "/tmp/clean.rkt")))
          msgs)))

(test-case "tab:close-request for dirty file sends dialog:confirm"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (mark-file-dirty! "/tmp/dirty.rkt")))
  (define output
    (with-output-to-string
      (lambda ()
        (handle-event
         (make-message "event" 'name "tab:close-request" 'path "/tmp/dirty.rkt")))))
  (define msgs (parse-all-messages output))
  ;; Should send dialog:confirm (not tab:close)
  (check-true
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "dialog:confirm"))
          msgs))
  (check-false
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "tab:close"))
          msgs)))
```

Note: This test requires importing `handle-event` from main.rkt. Since `handle-event` is defined in main.rkt and not exported, you'll need to either: (a) extract `handle-event` to a separate module, or (b) test at the integration level. **Recommendation:** For now, test `handle-tab-close-request` as a standalone function in `editor.rkt` that takes a path and returns the messages to send.

Revised approach — add `handle-tab-close-request` to `editor.rkt`:

```racket
;; Handle tab close request. If the file is dirty, returns a dialog:confirm
;; message. If clean, returns a tab:close message.
(define (handle-tab-close-request path)
  (cond
    [(file-dirty? path)
     (define filename (path->filename path))
     (send-message! (make-message "dialog:confirm"
                                  'id (format "close:~a" path)
                                  'title "Save Changes"
                                  'message (format "Do you want to save changes to ~a?" filename)
                                  'save_label "Save"
                                  'dont_save_label "Don't Save"
                                  'path path))]
    [else
     (send-message! (make-message "tab:close" 'path path))]))
```

**Step 2: Implement in editor.rkt and main.rkt**

In `editor.rkt`:
- Add `handle-tab-close-request` to provide list.
- Add the function as shown above.
- Add `handle-dialog-result` to handle dialog:confirm:result:

```racket
(define (handle-dialog-result msg)
  (define id (message-ref msg 'id ""))
  (define choice (message-ref msg 'choice "cancel"))
  (cond
    [(string-prefix? id "close:")
     (define path (substring id 6))
     (cond
       [(string=? choice "save")
        ;; Save first, then close on success
        (send-message! (make-message "editor:request-save"))
        ;; Set pending close so file:write:result triggers tab:close
        (set-pending-close! path)]
       [(string=? choice "dont-save")
        (mark-file-clean! path)
        (send-message! (make-message "tab:close" 'path path))]
       [else (void)])]  ;; cancel — do nothing
    [else (void)]))
```

In `main.rkt`:
- Add `tab:close-request` handler in `handle-event`:

```racket
[(string=? event-name "tab:close-request")
 (define path (message-ref msg 'path ""))
 (when (not (string=? path ""))
   (handle-tab-close-request path))]
```

- Add `dialog:confirm:result` handler in `dispatch`:

```racket
[(string=? typ "dialog:confirm:result")
 (handle-dialog-result msg)]
```

**Step 3: Update frontend tabs.js**

In `frontend/core/primitives/tabs.js`:

- Change `_closeTab` to dispatch `tab:close-request` instead of closing immediately:

```javascript
_closeTab(e, path) {
  e.stopPropagation();
  dispatch('tab:close-request', { path });
}
```

- Add bridge listener for `tab:close` in `firstUpdated()`:

```javascript
this._unsubs.push(
  onMessage('tab:close', (msg) => {
    const { path } = msg;
    this._tabs = this._tabs.filter(t => t.path !== path);
    if (this._activePath === path) {
      if (this._tabs.length > 0) {
        const newActive = this._tabs[this._tabs.length - 1].path;
        this._activePath = newActive;
        dispatch('tab:select', { path: newActive });
      } else {
        this._activePath = '';
        dispatch('tab:close-all');
      }
    }
    this.requestUpdate();
  })
);
```

**Step 4: Run tests**

Run: `racket test/test-phase4.rkt`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add racket/heavymental-core/editor.rkt racket/heavymental-core/main.rkt frontend/core/primitives/tabs.js test/test-phase4.rkt
git commit -m "feat: tab close with dirty-check dialog flow"
```

---

## Task 5: File Tree ↔ Editor Sync (Frontend)

Highlight the active file in the tree, auto-expand parent directories, scroll into view.

**Files:**
- Modify: `frontend/core/primitives/filetree.js`
- Test: `test/e2e/phase4.spec.js` (add sync tests)

**Step 1: Write failing E2E test**

Add to `test/e2e/phase4.spec.js`:

```javascript
// ── Group 2: File Tree Sync ──────────────────────────────────────────

test.describe('File tree editor sync', () => {
  test.beforeEach(async ({ page }) => {
    await bootApp(page);
    await sendBootMessages(page);
  });

  test('file tree highlights active file from current-file cell', async ({ page }) => {
    // Update current-file cell (simulating opening a file)
    await fireEvent(page, 'cell:update', {
      name: 'current-file',
      value: '/tmp/test-project/src/main.rkt',
    });

    await page.waitForTimeout(200);

    // The filetree should have an active item
    const activeItem = page.locator('hm-filetree .item.active');
    // Note: this may not find anything if the tree isn't expanded,
    // but the _activeFile property should be set
    const activeFile = await page.locator('hm-filetree').evaluate(
      (el) => el._activeFile
    );
    expect(activeFile).toBe('/tmp/test-project/src/main.rkt');
  });
});
```

**Step 2: Implement in filetree.js**

In `frontend/core/primitives/filetree.js`:

1. In `_resolveRootPath()`, add a second effect to watch `current-file` cell:

```javascript
// Sync active file with current-file cell
const currentFileCell = getCell('current-file');
this._disposeActiveSync = effect(() => {
  const filePath = currentFileCell.value;
  if (filePath && filePath !== this._activeFile) {
    this._activeFile = filePath;
    this._autoReveal(filePath);
    this.requestUpdate();
    // Scroll into view after render
    this.updateComplete.then(() => {
      const active = this.shadowRoot.querySelector('.item.active');
      if (active) active.scrollIntoView({ block: 'nearest' });
    });
  }
});
```

2. Add `_autoReveal` method:

```javascript
/**
 * Expand all ancestor directories of the given file path.
 * Computes parent paths relative to the resolved root and adds
 * them to _expanded, triggering lazy loads as needed.
 */
_autoReveal(filePath) {
  if (!this._resolvedRoot || !filePath.startsWith(this._resolvedRoot)) return;

  const rel = filePath.slice(this._resolvedRoot.length);
  const segments = rel.split('/').filter(Boolean);

  // Build up ancestor paths and expand each
  let current = this._resolvedRoot;
  for (let i = 0; i < segments.length - 1; i++) {
    current = current + '/' + segments[i];
    if (!this._expanded.has(current)) {
      this._expanded.add(current);
      this._loadDir(current);
    }
  }

  // Ensure root is expanded
  this._rootExpanded = true;
}
```

3. Clean up `_disposeActiveSync` in `disconnectedCallback()`.

**Step 3: Run tests**

Run: `cd test/e2e && npx playwright test phase4.spec.js --reporter=list`
Expected: File tree sync test passes.

**Step 4: Commit**

```bash
git add frontend/core/primitives/filetree.js test/e2e/phase4.spec.js
git commit -m "feat: file tree syncs with current-file cell, auto-reveals ancestors"
```

---

## Task 6: Save-Before-Run (Racket)

Auto-save dirty files before running.

**Files:**
- Modify: `racket/heavymental-core/main.rkt` (pending-run state machine)
- Modify: `racket/heavymental-core/editor.rkt` (pending-run + pending-close flags)
- Test: `test/test-phase4.rkt` (add save-before-run tests)

**Step 1: Write failing test**

Add to `test/test-phase4.rkt`:

```racket
;; ═══════════════════════════════════════════════════════════════════════════
;; Test: save-before-run
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "save-before-run: dirty file triggers editor:request-save"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "/tmp/test.rkt")
      (mark-file-dirty! "/tmp/test.rkt")))
  (define output
    (with-output-to-string
      (lambda ()
        (handle-run-with-save))))
  (define msgs (parse-all-messages output))
  ;; Should send editor:request-save (not pty:write)
  (check-true
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "editor:request-save"))
          msgs))
  (check-true (pending-run?)))

(test-case "save-before-run: clean file runs immediately"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "/tmp/test.rkt")))
  (define output
    (with-output-to-string
      (lambda ()
        (handle-run-with-save))))
  (define msgs (parse-all-messages output))
  ;; Should send pty:write directly (run)
  (check-true
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "pty:write"))
          msgs))
  (check-false (pending-run?)))
```

**Step 2: Implement pending-run state**

In `editor.rkt`, add:

```racket
;; ── Pending actions ─────────────────────────────────────────────
(define _pending-run #f)
(define _pending-close-paths (mutable-set))

(define (pending-run?) _pending-run)
(define (set-pending-run!) (set! _pending-run #t))
(define (clear-pending-run!) (set! _pending-run #f))

(define (set-pending-close! path) (set-add! _pending-close-paths path))
(define (pending-close? path) (set-member? _pending-close-paths path))
(define (clear-pending-close! path) (set-remove! _pending-close-paths path))
```

Add to provide: `pending-run?`, `set-pending-run!`, `clear-pending-run!`, `set-pending-close!`, `pending-close?`, `clear-pending-close!`, `handle-run-with-save`.

Add `handle-run-with-save`:

```racket
(define (handle-run-with-save)
  (define path (current-file-path))
  (cond
    [(or (not path) (string=? path "untitled.rkt"))
     (void)]  ;; can't run untitled
    [(file-dirty? path)
     (set-pending-run!)
     (send-message! (make-message "editor:request-save"))]
    [else
     (run-file path)]))
```

In `handle-file-result`, at the end of the `"file:write:result"` branch, add:

```racket
;; Check for pending actions
(when (pending-run?)
  (clear-pending-run!)
  (run-file path))
(when (pending-close? path)
  (clear-pending-close! path)
  (send-message! (make-message "tab:close" 'path path)))
```

In `main.rkt`, change `handle-run` to use the new function:

```racket
(define (handle-run)
  (handle-run-with-save))
```

Note: This also requires `run-file` to be importable from editor.rkt. Since `run-file` is in `repl.rkt`, add it to the import in `editor.rkt`:

```racket
(require ... "repl.rkt")
```

Wait — this creates a circular dependency since `repl.rkt` doesn't depend on `editor.rkt`, but `editor.rkt` calling `run-file` creates a coupling. Better approach: keep `handle-run-with-save` in `main.rkt` which already imports both `editor.rkt` and `repl.rkt`.

**Revised:** Move `handle-run-with-save` logic into `main.rkt`:

```racket
(define (handle-run)
  (define path (current-file-path))
  (cond
    [(or (not path) (string=? path "untitled.rkt")) (void)]
    [(file-dirty? path)
     (set-pending-run!)
     (send-message! (make-message "editor:request-save"))]
    [else
     (run-file path)]))
```

And the pending-run check goes in `handle-file-result` in `editor.rkt`, but needs `run-file`... So better: have `editor.rkt` export a callback-based approach. Or simplest: handle the pending-run check in `main.rkt`'s dispatch of `file:write:result`.

**Simplest approach:** In `main.rkt`, after calling `handle-file-result`, check pending-run:

```racket
[(or (string=? typ "file:read:result")
     (string=? typ "file:write:result")
     ...)
 (handle-file-result msg)
 ;; Check for pending actions after write
 (when (and (string=? typ "file:write:result") (pending-run?))
   (clear-pending-run!)
   (define path (message-ref msg 'path ""))
   (run-file path))
 (when (and (string=? typ "file:write:result"))
   (define path (message-ref msg 'path ""))
   (when (pending-close? path)
     (clear-pending-close! path)
     (send-message! (make-message "tab:close" 'path path))))]
```

**Step 3: Run tests**

Run: `racket test/test-phase4.rkt`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add racket/heavymental-core/editor.rkt racket/heavymental-core/main.rkt test/test-phase4.rkt
git commit -m "feat: save-before-run with pending-run state machine"
```

---

## Task 7: REPL Clear + Stop/Restart (Racket + Frontend)

Clear terminal before run, add stop/restart button.

**Files:**
- Modify: `racket/heavymental-core/repl.rkt` (add clear, restart, repl-running cell)
- Modify: `racket/heavymental-core/main.rkt` (add repl-running cell, repl:restart handler)
- Modify: `frontend/core/primitives/chrome.js` (`hm-breadcrumb` stop/play toggle)

**Step 1: Add clear and restart to repl.rkt**

In `repl.rkt`:

```racket
;; Clear the REPL terminal (send Ctrl+L)
(define (clear-repl)
  (send-message! (make-message "pty:write"
                               'id "repl"
                               'data "\x0c")))

;; Restart the REPL (kill + recreate)
(define (restart-repl)
  (send-message! (make-message "pty:kill" 'id "repl"))
  (start-repl))
```

Add to provide: `clear-repl`, `restart-repl`.

**Step 2: Add repl-running cell to main.rkt**

```racket
(define-cell repl-running #f)
```

Update `handle-run`:
```racket
(cell-set! 'repl-running #t)
(clear-repl)
(run-file path)
```

Update `handle-repl-event` dispatch in main.rkt to set `repl-running` to `#f` on `pty:exit`.

Add `repl:restart` handler in `handle-event`:
```racket
[(string=? event-name "repl:restart")
 (cell-set! 'repl-running #f)
 (restart-repl)]
```

**Step 3: Update breadcrumb play/stop toggle**

In `frontend/core/primitives/chrome.js`, update `HmBreadcrumb`:

1. In `_setupEffect()`, add `repl-running` cell to watched cells.
2. In `render()`:

```javascript
const isRunning = resolveValue('cell:repl-running') || false;

// In the actions div:
${isRunning
  ? html`<span class="action-btn stop" title="Stop (restart REPL)" @click=${() => this._dispatch('repl:restart')}>
      <svg width="14" height="14" viewBox="0 0 16 16"><rect x="3" y="3" width="10" height="10" rx="1" fill="currentColor"/></svg>
    </span>`
  : html`<span class="action-btn run" title="Run (Cmd+R)" @click=${() => this._dispatch('run')}>
      <svg width="14" height="14" viewBox="0 0 16 16"><path d="M4 2l10 6-10 6z" fill="currentColor"/></svg>
    </span>`
}
```

Add CSS for `.action-btn.stop:hover`:
```css
.action-btn.stop:hover {
  background: rgba(204, 0, 0, 0.1);
  color: #CC0000;
}
```

**Step 4: Add repl-running cell to E2E fixtures**

In `test/e2e/fixtures.js` CELLS:
```javascript
{ name: 'repl-running', value: false },
```

**Step 5: Run all tests**

Run: `racket test/test-phase4.rkt && cd test/e2e && npx playwright test phase4.spec.js --reporter=list`
Expected: All pass.

**Step 6: Commit**

```bash
git add racket/heavymental-core/repl.rkt racket/heavymental-core/main.rkt frontend/core/primitives/chrome.js test/e2e/fixtures.js
git commit -m "feat: REPL clear before run, stop/restart button in breadcrumb"
```

---

## Task 8: Tab Management Extras (Frontend)

Middle-click close, context menu (Close Others / Close All), tab overflow scroll.

**Files:**
- Modify: `frontend/core/primitives/tabs.js`
- Test: `test/e2e/phase4.spec.js`

**Step 1: Add middle-click close**

In `tabs.js`, add `@auxclick` handler to `.tab` div:

```javascript
@auxclick=${(e) => { if (e.button === 1) { e.preventDefault(); dispatch('tab:close-request', { path: tab.path }); } }}
```

**Step 2: Add context menu**

Add context menu state and rendering to `HmTabs`:

```javascript
// In constructor:
this._contextMenu = null; // { x, y, path }

// New method:
_showContextMenu(e, path) {
  e.preventDefault();
  const rect = this.getBoundingClientRect();
  this._contextMenu = {
    x: e.clientX - rect.left,
    y: e.clientY - rect.top,
    path,
  };
  this.requestUpdate();

  // Close on next click anywhere
  const close = () => {
    this._contextMenu = null;
    this.requestUpdate();
    document.removeEventListener('click', close);
  };
  setTimeout(() => document.addEventListener('click', close), 0);
}

_contextClose() {
  dispatch('tab:close-request', { path: this._contextMenu.path });
  this._contextMenu = null;
}

_contextCloseOthers() {
  const keep = this._contextMenu.path;
  for (const tab of this._tabs) {
    if (tab.path !== keep) dispatch('tab:close-request', { path: tab.path });
  }
  this._contextMenu = null;
}

_contextCloseAll() {
  for (const tab of this._tabs) {
    dispatch('tab:close-request', { path: tab.path });
  }
  this._contextMenu = null;
}
```

Add `@contextmenu=${(e) => this._showContextMenu(e, tab.path)}` to `.tab` div.

Add context menu rendering in `render()`:

```javascript
${this._contextMenu ? html`
  <div class="context-menu" style="left:${this._contextMenu.x}px;top:${this._contextMenu.y}px">
    <div class="ctx-item" @click=${() => this._contextClose()}>Close</div>
    <div class="ctx-item" @click=${() => this._contextCloseOthers()}>Close Others</div>
    <div class="ctx-item" @click=${() => this._contextCloseAll()}>Close All</div>
  </div>
` : ''}
```

Add CSS for context menu:

```css
.context-menu {
  position: absolute;
  z-index: 1000;
  background: var(--bg-primary, #ffffff);
  border: 1px solid var(--border, #d4d4d4);
  border-radius: 4px;
  box-shadow: 0 2px 8px rgba(0,0,0,0.15);
  padding: 4px 0;
  min-width: 120px;
}

.ctx-item {
  padding: 4px 12px;
  cursor: pointer;
  font-size: 13px;
}

.ctx-item:hover {
  background: var(--bg-tab-hover, #f0f0f0);
}
```

**Step 3: Add tab overflow scroll arrows**

Add scroll arrow buttons before and after `.tabs-area` in `render()`. Show only when tabs overflow:

```javascript
<div class="scroll-btn left" @click=${() => this._scrollTabs(-1)}>‹</div>
<div class="tabs-area" ${ref(this._tabsAreaRef)}>
  ...tabs...
</div>
<div class="scroll-btn right" @click=${() => this._scrollTabs(1)}>›</div>
```

```javascript
_scrollTabs(direction) {
  const area = this.shadowRoot.querySelector('.tabs-area');
  if (area) area.scrollBy({ left: direction * 120, behavior: 'smooth' });
}
```

Add CSS for scroll buttons (only visible on overflow).

**Step 4: Run tests**

Run: `cd test/e2e && npx playwright test phase4.spec.js --reporter=list`
Expected: All pass.

**Step 5: Commit**

```bash
git add frontend/core/primitives/tabs.js test/e2e/phase4.spec.js
git commit -m "feat: tab middle-click close, context menu, overflow scroll"
```

---

## Task 9: Stepper Racket Infrastructure

Create `stepper.rkt` that wraps Racket's stepper library and sends step data as JSON messages.

**Files:**
- Create: `racket/heavymental-core/stepper.rkt`
- Modify: `racket/heavymental-core/main.rkt` (import stepper, add cells, wire events)
- Test: `test/test-stepper.rkt` (new file)

**Step 1: Write failing test**

Create `test/test-stepper.rkt`:

```racket
#lang racket/base

(require rackunit
         json
         racket/port
         racket/string
         racket/file
         "../racket/heavymental-core/protocol.rkt"
         "../racket/heavymental-core/cell.rkt"
         "../racket/heavymental-core/stepper.rkt")

(define (parse-all-messages output)
  (define lines (string-split (string-trim output) "\n"))
  (for/list ([line (in-list lines)]
             #:when (> (string-length (string-trim line)) 0))
    (string->jsexpr line)))

;; Cells the stepper needs
(define-cell stepper-active #f)
(define-cell stepper-step 0)
(define-cell stepper-total -1)
(define-cell status "Ready")

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: stepper produces step results
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "stepper produces at least one step for a simple program"
  ;; Write a temp file with a simple program
  (define tmp (make-temporary-file "stepper-test-~a.rkt"))
  (with-output-to-file tmp #:exists 'replace
    (lambda ()
      (displayln "#lang racket")
      (displayln "(+ 1 2)")))

  (define output
    (with-output-to-string
      (lambda ()
        (start-stepper (path->string tmp)))))

  (define msgs (parse-all-messages output))

  ;; Should have at least one stepper:step message
  (define step-msgs
    (filter (lambda (m) (equal? (hash-ref m 'type #f) "stepper:step")) msgs))

  (check-true (> (length step-msgs) 0)
              "Expected at least one stepper:step message")

  ;; First step should have bindings (possibly empty list)
  (define first-step (car step-msgs))
  (check-true (hash-has-key? first-step 'bindings))

  ;; Should have finished with stepper:finished
  (check-true
   (ormap (lambda (m) (equal? (hash-ref m 'type #f) "stepper:finished")) msgs))

  (delete-file tmp))
```

**Step 2: Run test to verify it fails**

Run: `racket test/test-stepper.rkt`
Expected: FAIL — `stepper.rkt` doesn't exist.

**Step 3: Implement stepper.rkt**

Create `racket/heavymental-core/stepper.rkt`:

```racket
#lang racket/base

(require racket/match
         racket/port
         racket/sandbox
         stepper/private/model
         stepper/private/shared
         stepper/private/shared-typed
         stepper/private/model-settings
         "protocol.rkt"
         "cell.rkt")

(provide start-stepper
         stop-stepper
         stepper-active?)

;; ── State ──────────────────────────────────────────────────────────
(define _stepper-active #f)
(define _stepper-custodian #f)
(define _step-count 0)

(define (stepper-active?) _stepper-active)

(define (stop-stepper)
  (when _stepper-custodian
    (custodian-shutdown-all _stepper-custodian)
    (set! _stepper-custodian #f))
  (set! _stepper-active #f)
  (set! _step-count 0)
  (cell-set! 'stepper-active #f)
  (cell-set! 'stepper-step 0)
  (send-message! (make-message "stepper:finished")))

;; ── Convert step result to JSON-friendly data ─────────────────────
(define (step-result->json result)
  (match result
    [(Before-After-Result pre-exps post-exps kind pre-src post-src)
     (hasheq 'type "before-after"
             'before (map syntax->string-safe pre-exps)
             'after (map syntax->string-safe post-exps)
             'kind (symbol->string kind)
             'pre-src (posn-info->json pre-src)
             'post-src (posn-info->json post-src))]
    [(Before-Error-Result pre-exps err-msg pre-src)
     (hasheq 'type "before-error"
             'before (map syntax->string-safe pre-exps)
             'error err-msg
             'pre-src (posn-info->json pre-src))]
    [(Error-Result err-msg)
     (hasheq 'type "error"
             'error err-msg)]
    ['finished-stepping
     (hasheq 'type "finished")]
    [_ (hasheq 'type "unknown")]))

(define (posn-info->json pi)
  (if pi
      (hasheq 'position (Posn-Info-posn pi)
              'span (Posn-Info-span pi))
      #f))

(define (syntax->string-safe stx)
  (with-handlers ([exn:fail? (lambda (e) "#<syntax>")])
    (format "~a" (syntax->datum stx))))

;; ── Start stepping ─────────────────────────────────────────────────
(define (start-stepper file-path)
  (stop-stepper)  ;; clean up any previous session

  (set! _stepper-active #t)
  (set! _step-count 0)
  (cell-set! 'stepper-active #t)
  (cell-set! 'stepper-step 0)
  (cell-set! 'status (format "Stepping ~a" file-path))

  (define cust (make-custodian))
  (set! _stepper-custodian cust)

  ;; Read the source
  (define source-text (file->string file-path))

  ;; Create the program expander
  ;; The stepper's `go` function expects a program-expander that:
  ;; 1. Calls init-thunk
  ;; 2. Calls iter with each top-level form (as syntax) and a continuation
  ;; 3. Calls iter with eof when done
  (define (program-expander init-thunk iter)
    (init-thunk)
    (define input-port (open-input-string source-text))
    (port-count-lines! input-port)
    (define source-name file-path)
    (let loop ()
      (define stx (read-syntax source-name input-port))
      (cond
        [(eof-object? stx)
         (iter eof void)]
        [else
         (iter stx void)
         (loop)])))

  ;; Result receiver — called for each step
  (define (receive-result result)
    (set! _step-count (add1 _step-count))
    (cell-set! 'stepper-step _step-count)
    (define json-data (step-result->json result))
    (send-message! (make-message "stepper:step"
                                 'step _step-count
                                 'data json-data))
    (when (equal? result 'finished-stepping)
      (stop-stepper)))

  ;; Run the stepper
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (send-message! (make-message "stepper:error"
                                                  'error (exn-message e)))
                     (stop-stepper))])
    (parameterize ([current-custodian cust])
      (go program-expander
          void  ;; dynamic-requirer (not needed for basic stepping)
          receive-result
          #f))))  ;; render-settings (#f = default)
```

**Step 4: Add stepper cells and event wiring to main.rkt**

In `main.rkt`:

1. Add to requires: `"stepper.rkt"`
2. Add cells:

```racket
(define-cell stepper-active #f)
(define-cell stepper-step 0)
(define-cell stepper-total -1)
```

3. Add to menu (Racket submenu):

```racket
(hasheq 'label "Step Through" 'shortcut "Cmd+Shift+R" 'action "step-through")
(hasheq 'label "Stop Stepper" 'action "stop-stepper")
```

4. Add event handlers:

```racket
[(string=? event-name "stepper:start")
 (define path (message-ref msg 'path (current-file-path)))
 (when (and path (not (string=? path "")))
   (start-stepper path))]
[(string=? event-name "stepper:stop")
 (stop-stepper)]
```

5. Add menu action handlers:

```racket
[(string=? action "step-through")
 (define path (current-file-path))
 (when (and path (not (string=? path "untitled.rkt")))
   (start-stepper path))]
[(string=? action "stop-stepper")
 (stop-stepper)]
```

**Step 5: Run test**

Run: `racket test/test-stepper.rkt`
Expected: Stepper test passes (produces at least one step for `(+ 1 2)`).

Note: The stepper library may require `htdp-lib` or specific Teaching Language setup. If it fails because the stepper only works with Teaching Languages, we'll need to adjust the approach — possibly using `errortrace` instrumentation instead. This is a known risk documented in the design.

**Step 6: Commit**

```bash
git add racket/heavymental-core/stepper.rkt racket/heavymental-core/main.rkt test/test-stepper.rkt
git commit -m "feat: stepper infrastructure using Racket's stepper/private/model"
```

---

## Task 10: Stepper Frontend UI

Expression highlighting in Monaco + bindings panel + stepper toolbar.

**Files:**
- Create: `frontend/core/primitives/stepper.js` (hm-stepper-toolbar + hm-bindings-panel)
- Modify: `frontend/core/primitives/editor.js` (stepper highlight decorations)
- Modify: `frontend/core/renderer.js` (register new component types)
- Modify: `racket/heavymental-core/main.rkt` (add stepper panel to layout)
- Test: `test/e2e/phase4.spec.js` (stepper UI tests)

**Step 1: Create stepper.js with both components**

Create `frontend/core/primitives/stepper.js`:

```javascript
// primitives/stepper.js — hm-stepper-toolbar + hm-bindings-panel
//
// Stepper UI components. The toolbar provides Step Forward/Back/Continue/Stop.
// The bindings panel shows variable→value pairs from the current step.

import { LitElement, html, css } from 'lit';
import { effect } from '@preact/signals-core';
import { getCell } from '../cells.js';
import { onMessage, dispatch } from '../bridge.js';

// ── hm-stepper-toolbar ──────────────────────────────────────

class HmStepperToolbar extends LitElement {
  static styles = css`
    :host {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      background: var(--bg-toolbar, #F8F8F8);
      border-bottom: 1px solid var(--border, #D4D4D4);
      font-family: var(--font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif);
      font-size: 13px;
      min-height: 28px;
      flex-shrink: 0;
    }

    :host([hidden]) { display: none; }

    button {
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

    button:hover {
      background: var(--bg-tab-hover, #F0F0F0);
    }

    .step-info {
      margin-left: auto;
      color: var(--fg-muted, #999999);
    }
  `;

  constructor() {
    super();
    this._disposeEffect = null;
    this._unsubs = [];
  }

  firstUpdated() {
    setTimeout(() => {
      const activeCell = getCell('stepper-active');
      this._disposeEffect = effect(() => {
        this.toggleAttribute('hidden', !activeCell.value);
      });
    }, 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._disposeEffect) this._disposeEffect();
    for (const u of this._unsubs) u();
  }

  render() {
    return html`
      <button @click=${() => dispatch('stepper:forward')}>Step →</button>
      <button @click=${() => dispatch('stepper:back')}>← Back</button>
      <button @click=${() => dispatch('stepper:continue')}>Continue</button>
      <button @click=${() => dispatch('stepper:stop')}>Stop</button>
      <span class="step-info">Step <span id="step-num">0</span></span>
    `;
  }
}

customElements.define('hm-stepper-toolbar', HmStepperToolbar);

// ── hm-bindings-panel ───────────────────────────────────────

class HmBindingsPanel extends LitElement {
  static styles = css`
    :host {
      display: block;
      overflow-y: auto;
      padding: 8px 12px;
      font-family: var(--font-editor, "SF Mono", Menlo, monospace);
      font-size: 13px;
      font-weight: var(--font-editor-weight, 300);
      background: var(--bg-primary, #FFFFFF);
      color: var(--fg-primary, #333333);
    }

    :host([hidden]) { display: none; }

    .binding {
      display: flex;
      gap: 12px;
      padding: 2px 0;
      border-bottom: 1px solid var(--border-light, #F0F0F0);
    }

    .name {
      color: var(--accent, #007ACC);
      min-width: 80px;
    }

    .value {
      color: var(--fg-secondary, #616161);
    }

    .empty {
      color: var(--fg-muted, #999999);
      font-style: italic;
    }

    .step-expr {
      margin-bottom: 8px;
      padding: 6px 8px;
      background: #FFFDE7;
      border-left: 3px solid #FBC02D;
      border-radius: 2px;
    }

    .step-label {
      font-size: 11px;
      color: var(--fg-muted, #999999);
      margin-bottom: 4px;
    }
  `;

  constructor() {
    super();
    this._bindings = [];
    this._before = '';
    this._after = '';
    this._unsubs = [];
    this._disposeEffect = null;
  }

  firstUpdated() {
    setTimeout(() => {
      this._unsubs.push(
        onMessage('stepper:step', (msg) => {
          const data = msg.data || {};
          this._bindings = data.bindings || [];
          this._before = (data.before || []).join(' ');
          this._after = (data.after || []).join(' ');
          this.requestUpdate();
        })
      );

      const activeCell = getCell('stepper-active');
      this._disposeEffect = effect(() => {
        this.toggleAttribute('hidden', !activeCell.value);
      });
    }, 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._disposeEffect) this._disposeEffect();
    for (const u of this._unsubs) u();
  }

  render() {
    return html`
      ${this._before ? html`
        <div class="step-expr">
          <div class="step-label">Before:</div>
          <code>${this._before}</code>
        </div>` : ''}
      ${this._after ? html`
        <div class="step-expr">
          <div class="step-label">After:</div>
          <code>${this._after}</code>
        </div>` : ''}
      ${this._bindings.length > 0
        ? this._bindings.map(b => html`
            <div class="binding">
              <span class="name">${b.name}</span>
              <span class="value">${b.value}</span>
            </div>`)
        : html`<div class="empty">No bindings</div>`}
    `;
  }
}

customElements.define('hm-bindings-panel', HmBindingsPanel);
```

**Step 2: Register new components in renderer.js**

Check `frontend/core/renderer.js` for the component import list and add:

```javascript
import './primitives/stepper.js';
```

The renderer's `type` → `hm-<type>` mapping should automatically pick up `stepper-toolbar` and `bindings-panel` if the layout tree uses those types.

**Step 3: Add stepper highlight to editor.js**

In `frontend/core/primitives/editor.js`, add a bridge listener for `stepper:step`:

```javascript
// Stepper expression highlighting
this._stepperDecorations = [];
this._unsubs.push(
  onMessage('stepper:step', (msg) => {
    if (!this._editor || !this._monaco) return;
    const data = msg.data || {};
    const src = data.pre_src || data.pre-src;
    if (src && src.position != null && src.span != null) {
      const model = this._editor.getModel();
      if (!model) return;
      const startPos = model.getPositionAt(src.position - 1); // 1-based offset
      const endPos = model.getPositionAt(src.position - 1 + src.span);
      this._stepperDecorations = this._editor.deltaDecorations(
        this._stepperDecorations,
        [{
          range: new this._monaco.Range(
            startPos.lineNumber, startPos.column,
            endPos.lineNumber, endPos.column
          ),
          options: {
            className: 'hm-stepper-highlight',
            isWholeLine: false,
          },
        }]
      );
      this._editor.revealRangeInCenter(new this._monaco.Range(
        startPos.lineNumber, startPos.column,
        endPos.lineNumber, endPos.column
      ));
    }
  })
);

// Clear stepper decorations when stepper stops
this._unsubs.push(
  onMessage('stepper:finished', () => {
    if (this._editor) {
      this._stepperDecorations = this._editor.deltaDecorations(
        this._stepperDecorations, []
      );
    }
  })
);
```

Add stepper highlight CSS in `_initMonaco()`:

```javascript
const stepperStyle = document.createElement('style');
stepperStyle.textContent = `
  .hm-stepper-highlight { background: rgba(255, 235, 59, 0.3) !important; }
`;
this.shadowRoot.appendChild(stepperStyle);
```

**Step 4: Add stepper panel to layout in main.rkt**

Update the bottom panel section of `initial-layout` in `main.rkt` to include the stepper:

```racket
(hasheq 'type "vbox"
        'props (hasheq 'flex "1")
        'children
        (list
         (hasheq 'type "panel-header"
                 'props (hasheq 'label "TERMINAL")
                 'children (list))
         (hasheq 'type "terminal"
                 'props (hasheq 'pty-id "repl")
                 'children (list))
         (hasheq 'type "panel-header"
                 'props (hasheq 'label "PROBLEMS")
                 'children (list))
         (hasheq 'type "error-panel"
                 'props (hasheq)
                 'children (list))
         (hasheq 'type "stepper-toolbar"
                 'props (hasheq)
                 'children (list))
         (hasheq 'type "bindings-panel"
                 'props (hasheq)
                 'children (list))))
```

Note: The stepper-toolbar and bindings-panel will be hidden by default (they toggle visibility based on the `stepper-active` cell).

**Step 5: Import stepper.js in index.html or renderer**

Ensure the stepper primitives are loaded. Add to `frontend/core/renderer.js`:

```javascript
import './primitives/stepper.js';
```

**Step 6: Run E2E tests**

Run: `cd test/e2e && npx playwright test phase4.spec.js --reporter=list`
Expected: All pass.

**Step 7: Commit**

```bash
git add frontend/core/primitives/stepper.js frontend/core/primitives/editor.js frontend/core/renderer.js racket/heavymental-core/main.rkt test/e2e/phase4.spec.js
git commit -m "feat: stepper UI — toolbar, bindings panel, expression highlighting"
```

---

## Task 11: Integration Testing + Final Polish

Run the full app end-to-end, fix any issues, add comprehensive E2E tests.

**Files:**
- Modify: `test/e2e/phase4.spec.js` (add integration tests)
- Modify: various files as bugs are found

**Step 1: Add comprehensive E2E tests**

Add to `test/e2e/phase4.spec.js`:

```javascript
// ── Group 3: Run Experience ──────────────────────────────────────────

test.describe('Run experience', () => {
  test.beforeEach(async ({ page }) => {
    await bootApp(page);
    await sendBootMessages(page);
    await waitForMonaco(page);
  });

  test('run button toggles to stop when repl-running is true', async ({ page }) => {
    // Initially should show play button
    const breadcrumb = page.locator('hm-breadcrumb');
    await fireEvent(page, 'cell:update', { name: 'current-file', value: '/tmp/test.rkt' });
    await page.waitForTimeout(100);

    const playBtn = breadcrumb.locator('.action-btn.run');
    await expect(playBtn).toBeVisible();

    // Set repl-running to true
    await fireEvent(page, 'cell:update', { name: 'repl-running', value: true });
    await page.waitForTimeout(100);

    // Should now show stop button
    const stopBtn = breadcrumb.locator('.action-btn.stop');
    await expect(stopBtn).toBeVisible();
  });
});

// ── Group 4: Tab Management ─────────────────────────────────────────

test.describe('Tab management', () => {
  test.beforeEach(async ({ page }) => {
    await bootApp(page);
    await sendBootMessages(page);
    await waitForMonaco(page);
  });

  test('tab:close message removes a tab', async ({ page }) => {
    // Open two files
    await fireEvent(page, 'editor:open', { path: '/tmp/a.rkt', content: '', language: 'racket' });
    await fireEvent(page, 'editor:open', { path: '/tmp/b.rkt', content: '', language: 'racket' });
    await page.waitForTimeout(100);

    const tabs = page.locator('hm-tabs .tab');
    await expect(tabs).toHaveCount(2);

    // Close tab via bridge message
    await fireEvent(page, 'tab:close', { path: '/tmp/a.rkt' });
    await page.waitForTimeout(100);

    await expect(tabs).toHaveCount(1);
  });
});
```

**Step 2: Run all tests**

```bash
racket test/test-phase4.rkt
racket test/test-stepper.rkt
racket test/test-phase2.rkt
racket test/test-bridge.rkt
racket test/test-lang-intel.rkt
cd test/e2e && npx playwright test --reporter=list
```

Expected: All tests pass.

**Step 3: Manual smoke test**

Run: `cargo tauri dev`

Test flow:
1. Click a `.rkt` file in the tree → opens in editor, tab appears
2. Type something → tab shows `•` dirty dot
3. Cmd+S → dot disappears, status bar shows "Saved"
4. Cmd+R → REPL clears, file runs, output appears
5. Close tab → dirty check dialog (if dirty)
6. Cmd+Shift+R → stepper starts (if stepper library compatible)

**Step 4: Final commit**

```bash
git add -A
git commit -m "feat: Phase 4 complete — end-to-end usability + basic stepper"
```

---

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| Racket stepper only works with Teaching Languages | Stepper won't work with `#lang racket` | Fall back to errortrace instrumentation. Document as known limitation. |
| Dialog plugin `OkCancelCustom` doesn't support Cancel button | No way to cancel close | Use `AskDialog` with Yes/No, treat close as cancel. |
| WKWebView deadlock from new effects | Blank screen / hang on macOS | Follow existing pattern: defer effects with `setTimeout(() => ..., 0)` |
| Per-tab dirty state sync issues | Stale dirty dots | Add cell update on every save/dirty event, not just current file |
