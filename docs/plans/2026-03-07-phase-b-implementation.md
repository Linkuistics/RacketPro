# Phase B: Macro Debugger Integration + Pattern Highlighting — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the hand-rolled `expand-once` macro expansion engine with Racket's `macro-debugger/model/*` APIs, providing structured expansion steps with foci highlighting, macro identity, and source-level pattern extraction for `syntax-parse` macros.

**Architecture:** Racket uses `trace/result` → `reductions` to produce flat step lists with syntax objects, source locations, and foci data. The frontend gains a dual-view macro panel (tree + stepper) with a shared detail pane showing before/after with foci highlighting and optional pattern display. A new `pattern-extractor.rkt` module reads macro source files to extract `syntax-parse` patterns.

**Tech Stack:** Racket (`macro-debugger/model/*`, `syntax/parse`), Lit Web Components, JSON-RPC protocol

**Design doc:** `docs/plans/2026-03-07-phase-b-macro-debugger-design.md`

---

## Task 1: Rewrite expansion engine with macro-debugger

**Files:**
- Modify: `racket/heavymental-core/macro-expander.rkt` (full rewrite)
- Modify: `test/test-macro-expander.rkt` (rewrite tests for new API)

This task replaces the core expansion engine. The existing `expand-once` loop becomes `trace/result` + `reductions` from `macro-debugger/model/*`.

### Step 1: Write failing tests for the new expansion engine

Replace the test file contents. The new tests verify that `start-macro-expander` emits `macro:steps` messages (not `macro:tree`), and each step has the expected structure.

```racket
#lang racket/base

(require rackunit
         json
         racket/file
         racket/port
         racket/string
         racket/list
         "../racket/heavymental-core/protocol.rkt"
         "../racket/heavymental-core/cell.rkt"
         "../racket/heavymental-core/macro-expander.rkt")

;; ── Helpers ──────────────────────────────────────────────────────────────────

(define (parse-all-messages output)
  (define lines (string-split (string-trim output) "\n"))
  (for/list ([line (in-list lines)]
             #:when (> (string-length (string-trim line)) 0))
    (string->jsexpr line)))

(define (find-message-by-type msgs type)
  (findf (lambda (m) (string=? (hash-ref m 'type "") type)) msgs))

(define (find-all-messages-by-type msgs type)
  (filter (lambda (m) (string=? (hash-ref m 'type "") type)) msgs))

;; ── Ensure cells exist ──────────────────────────────────────────────────────
(define-cell macro-active #f)
(define-cell current-bottom-tab "terminal")

(define (reset-state!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'macro-active #f)
      (cell-set! 'current-bottom-tab "terminal"))))

(define (make-temp-rkt-file content)
  (define tmp (make-temporary-file "macro-test-~a.rkt"))
  (call-with-output-file tmp
    (lambda (out) (display content out))
    #:exists 'replace)
  tmp)

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: macro:steps message structure
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "start-macro-expander emits macro:steps for cond expression"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))

  ;; Should contain a macro:steps message
  (define steps-msg (find-message-by-type msgs "macro:steps"))
  (check-not-false steps-msg "macro:steps message should be present")
  (check-true (list? (hash-ref steps-msg 'steps))
              "macro:steps should contain a 'steps list")
  (check-true (> (length (hash-ref steps-msg 'steps)) 0)
              "should have at least one step")

  ;; macro-active cell should be #t
  (check-equal? (cell-ref 'macro-active) #t)
  ;; current-bottom-tab should be switched to "macros"
  (check-equal? (cell-ref 'current-bottom-tab) "macros")

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

(test-case "each step has expected fields"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))
  (define steps-msg (find-message-by-type msgs "macro:steps"))
  (define steps (hash-ref steps-msg 'steps))
  (define first-step (car steps))

  ;; Required fields
  (check-true (hash-has-key? first-step 'id) "step should have 'id")
  (check-true (hash-has-key? first-step 'type) "step should have 'type")
  (check-true (hash-has-key? first-step 'typeLabel) "step should have 'typeLabel")
  (check-true (hash-has-key? first-step 'before) "step should have 'before")
  (check-true (hash-has-key? first-step 'after) "step should have 'after")
  (check-true (hash-has-key? first-step 'foci) "step should have 'foci")
  (check-true (hash-has-key? first-step 'fociAfter) "step should have 'fociAfter")

  ;; First step for cond should be a macro step
  (check-equal? (hash-ref first-step 'type) "macro"
                "first step of cond expansion should be type 'macro'")

  ;; 'before' should be a string containing "cond"
  (check-true (string-contains? (hash-ref first-step 'before) "cond")
              "before text should contain 'cond'")

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

(test-case "macro steps include macro name and module"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))
  (define steps (hash-ref (find-message-by-type msgs "macro:steps") 'steps))

  ;; Find a macro-type step
  (define macro-steps (filter (lambda (s) (string=? (hash-ref s 'type "") "macro")) steps))
  (check-true (> (length macro-steps) 0) "should have at least one macro step")

  (define first-macro (car macro-steps))
  (check-true (hash-has-key? first-macro 'macro) "macro step should have 'macro field")
  (check-true (string? (hash-ref first-macro 'macro)) "macro name should be a string")

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

(test-case "foci contain offset/span pairs"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))
  (define steps (hash-ref (find-message-by-type msgs "macro:steps") 'steps))
  (define first-step (car steps))
  (define foci (hash-ref first-step 'foci))

  ;; Foci should be a list
  (check-true (list? foci) "foci should be a list")
  ;; Each focus item should have offset and span
  (when (> (length foci) 0)
    (define f (car foci))
    (check-true (hash-has-key? f 'offset) "focus should have 'offset")
    (check-true (hash-has-key? f 'span) "focus should have 'span"))

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: non-macro code
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "start-macro-expander works with non-macro code"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(+ 1 2)\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))

  ;; Should still produce macro:steps (may have tag steps but no macro steps)
  (define steps-msg (find-message-by-type msgs "macro:steps"))
  (check-not-false steps-msg "macro:steps should be sent even for non-macro code")

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: error handling
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "start-macro-expander sends macro:error for syntax errors"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(define x (+ 1\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))

  (define error-msg (find-message-by-type msgs "macro:error"))
  (check-not-false error-msg "macro:error message should be present for syntax errors")
  (check-true (string? (hash-ref error-msg 'error ""))
              "macro:error should contain an error string")
  (check-equal? (cell-ref 'macro-active) #f)

  (delete-file tmp))

(test-case "start-macro-expander does not crash on empty file"
  (reset-state!)
  (define tmp (make-temp-rkt-file ""))
  (check-not-exn
    (lambda ()
      (with-output-to-string
        (lambda ()
          (start-macro-expander (path->string tmp))))))
  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: stop-macro-expander
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "stop-macro-expander resets macro-active cell to #f"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(+ 1 2)\n"))
  (with-output-to-string
    (lambda () (start-macro-expander (path->string tmp))))
  (check-equal? (cell-ref 'macro-active) #t)

  (with-output-to-string
    (lambda () (stop-macro-expander)))
  (check-equal? (cell-ref 'macro-active) #f)
  (delete-file tmp))

(test-case "stop-macro-expander sends macro:clear message"
  (reset-state!)
  (define output
    (with-output-to-string
      (lambda () (stop-macro-expander))))
  (define msgs (parse-all-messages output))
  (define clear-msg (find-message-by-type msgs "macro:clear"))
  (check-not-false clear-msg "macro:clear message should be sent"))

(test-case "stop-macro-expander can be called multiple times without crashing"
  (reset-state!)
  (check-not-exn
    (lambda ()
      (with-output-to-string
        (lambda ()
          (stop-macro-expander)
          (stop-macro-expander)
          (stop-macro-expander))))))

(test-case "stop-macro-expander can be called without prior start"
  (reset-state!)
  (check-not-exn
    (lambda ()
      (with-output-to-string
        (lambda ()
          (stop-macro-expander))))))

(test-case "start then stop then start again works correctly"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(when #t 42)\n"))

  (with-output-to-string
    (lambda () (start-macro-expander (path->string tmp))))
  (check-equal? (cell-ref 'macro-active) #t)

  (with-output-to-string
    (lambda () (stop-macro-expander)))
  (check-equal? (cell-ref 'macro-active) #f)

  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))
  (define steps-msg (find-message-by-type msgs "macro:steps"))
  (check-not-false steps-msg "macro:steps should work on second invocation")
  (check-equal? (cell-ref 'macro-active) #t)

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: step filtering
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "steps include only rewrite steps by default"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))
  (define steps (hash-ref (find-message-by-type msgs "macro:steps") 'steps))

  ;; All steps should have a valid type
  (for ([s steps])
    (check-true (member (hash-ref s 'type)
                        '("macro" "tag-module-begin" "tag-app" "tag-datum"
                          "tag-top" "finish-block" "finish-expr" "block->letrec"
                          "splice-block" "splice-module" "splice-lifts"
                          "splice-end-lifts" "capture-lifts" "provide"
                          "finish-lsv"))
                (format "unexpected step type: ~a" (hash-ref s 'type))))

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

(displayln "All macro expander tests passed!")
```

**Step 2: Run tests to verify they fail**

Run: `racket test/test-macro-expander.rkt`
Expected: FAIL — current implementation emits `macro:tree`, not `macro:steps`

### Step 3: Rewrite macro-expander.rkt

Replace the full contents of `racket/heavymental-core/macro-expander.rkt`:

```racket
#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/pretty
         racket/string
         macro-debugger/model/trace
         macro-debugger/model/reductions
         macro-debugger/model/steps
         macro-debugger/model/deriv
         "protocol.rkt"
         "cell.rkt")

(provide start-macro-expander
         stop-macro-expander)

;; ── State ─────────────────────────────────────────────────────
(define _macro-active #f)
(define _step-counter 0)

(define (next-step-id!)
  (set! _step-counter (add1 _step-counter))
  (format "step-~a" (sub1 _step-counter)))

;; ── Syntax utilities ──────────────────────────────────────────

;; Pretty-print a syntax object to a compact string
(define (syntax->string stx)
  (define out (open-output-string))
  (pretty-write (syntax->datum stx) out)
  (string-trim (get-output-string out)))

;; Extract the macro name from a step, using the derivation data if available
;; For rewrite steps, check base-resolves on related derivation nodes
(define (step-macro-name s)
  ;; The foci in state-s1 tell us what's being transformed.
  ;; The first focus usually is the form whose head is the macro name.
  (define foci (state-foci (protostep-s1 s)))
  (if (and (pair? foci) (syntax? (car foci)))
      (let ([datum (syntax->datum (car foci))])
        (if (and (pair? datum) (symbol? (car datum)))
            (symbol->string (car datum))
            #f))
      #f))

;; Serialize a syntax object's position info
(define (syntax-loc stx)
  (define pos (syntax-position stx))
  (define spn (syntax-span stx))
  (if (and pos spn)
      (hasheq 'offset pos 'span spn)
      #f))

;; Serialize focus syntax objects as offset/span pairs
(define (serialize-foci foci-list)
  (for/list ([f (in-list foci-list)]
             #:when (and (syntax-position f) (syntax-span f)))
    (hasheq 'offset (syntax-position f)
            'span (syntax-span f))))

;; Convert a step type symbol to a clean string
(define (type-sym->string sym)
  (define s (symbol->string sym))
  ;; Strip "tag-" prefix, convert "finish-" etc.
  (cond
    [(string-prefix? s "tag-") (string-append "tag-" (substring s 4))]
    [else s]))

;; ── Step serialization ───────────────────────────────────────

(define (step->json s)
  (define id (next-step-id!))
  (define type-sym (protostep-type s))
  (define before-stx (step-term1 s))
  (define after-stx (step-term2 s))
  (define s1 (protostep-s1 s))
  (define s2 (step-s2 s))

  (hasheq 'id id
          'type (type-sym->string type-sym)
          'typeLabel (step-type->string type-sym)
          'macro (step-macro-name s)
          'before (syntax->string before-stx)
          'after (syntax->string after-stx)
          'beforeLoc (syntax-loc before-stx)
          'foci (serialize-foci (state-foci s1))
          'fociAfter (serialize-foci (state-foci s2))
          'seq (state-seq s1)))

;; ── Public API ────────────────────────────────────────────────

(define (start-macro-expander path)
  (set! _macro-active #t)
  (set! _step-counter 0)
  (cell-set! 'macro-active #t)

  (with-handlers ([exn:fail?
                    (lambda (e)
                      (send-message! (make-message "macro:error"
                                                   'error (exn-message e)))
                      (stop-macro-expander))])
    ;; Read the source file
    (define text (file->string path))
    (define port (open-input-string text))
    (port-count-lines! port)

    ;; Read all top-level forms as syntax
    ;; Skip #lang line by using read-language first
    (with-handlers ([exn:fail? (lambda (e) (void))])
      (read-language port (lambda () #f)))

    ;; Read all remaining forms
    (define forms
      (let loop ([acc '()])
        (define stx (read-syntax path port))
        (if (eof-object? stx)
            (reverse acc)
            (loop (cons stx acc)))))

    ;; If no forms, emit empty steps
    (when (null? forms)
      (send-message! (make-message "macro:steps" 'steps (list)))
      (cell-set! 'current-bottom-tab "macros")
      (set! _macro-active #t)  ;; keep active for cell state
      (void))

    ;; Trace each top-level form and collect steps
    (unless (null? forms)
      (define all-steps
        (apply append
               (for/list ([form (in-list forms)])
                 (with-handlers ([exn:fail? (lambda (e) (list))])
                   (define-values (result deriv) (trace/result form))
                   (define rw-steps (filter rewrite-step? (reductions deriv)))
                   rw-steps))))

      ;; Serialize and send
      (define step-jsons (for/list ([s all-steps]) (step->json s)))
      (send-message! (make-message "macro:steps" 'steps step-jsons))
      (cell-set! 'current-bottom-tab "macros"))))

(define (stop-macro-expander)
  (set! _macro-active #f)
  (cell-set! 'macro-active #f)
  (send-message! (make-message "macro:clear")))
```

### Step 4: Run tests to verify they pass

Run: `racket test/test-macro-expander.rkt`
Expected: All tests PASS

Note: Some tests may need adjustment if `step-type->string` returns different labels than expected, or if `trace/result` requires a namespace. Debug and fix iteratively — the macro-debugger API is well-tested but may need a namespace parameter:

```racket
;; If trace/result fails without a namespace, try:
(parameterize ([current-namespace (make-base-namespace)])
  (define-values (result deriv) (trace/result form))
  ...)
```

### Step 5: Commit

```bash
git add racket/heavymental-core/macro-expander.rkt test/test-macro-expander.rkt
git commit -m "feat: replace expand-once with macro-debugger trace/result engine

Use macro-debugger/model/* APIs for structured expansion steps with
foci, source locations, and macro identity. Emits macro:steps instead
of macro:tree."
```

---

## Task 2: Add macro filter support

**Files:**
- Modify: `racket/heavymental-core/macro-expander.rkt`
- Modify: `test/test-macro-expander.rkt`

Add the ability to filter which step types are included, and add a `macroOnly` parameter to `start-macro-expander`.

### Step 1: Write failing test

Add to `test/test-macro-expander.rkt`:

```racket
(test-case "macro-only filter excludes tag and rename steps"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp) #:macro-only? #t))))
  (define msgs (parse-all-messages output))
  (define steps (hash-ref (find-message-by-type msgs "macro:steps") 'steps))

  ;; All steps should be of type "macro"
  (for ([s steps])
    (check-equal? (hash-ref s 'type) "macro"
                  (format "expected macro, got ~a" (hash-ref s 'type))))

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))
```

### Step 2: Run test to verify it fails

Run: `racket test/test-macro-expander.rkt`
Expected: FAIL — `start-macro-expander` doesn't accept `#:macro-only?`

### Step 3: Add `#:macro-only?` keyword argument

In `macro-expander.rkt`, modify `start-macro-expander`:

```racket
(define (start-macro-expander path #:macro-only? [macro-only? #f])
  ;; ... existing code ...
  ;; After getting rw-steps, add:
  (define filtered-steps
    (if macro-only?
        (filter (lambda (s) (eq? (protostep-type s) 'macro)) rw-steps)
        rw-steps))
  ;; Use filtered-steps instead of rw-steps for serialization
  ...)
```

### Step 4: Run tests

Run: `racket test/test-macro-expander.rkt`
Expected: PASS

### Step 5: Commit

```bash
git add racket/heavymental-core/macro-expander.rkt test/test-macro-expander.rkt
git commit -m "feat: add macro-only filter to expansion steps"
```

---

## Task 3: Build the stepper view in the frontend

**Files:**
- Modify: `frontend/core/primitives/macro-panel.js` (major rewrite)

This task rewrites the frontend component to support the new `macro:steps` message format and adds the stepper view with navigation.

### Step 1: Rewrite `hm-macro-panel` for stepper view

Replace the full contents of `frontend/core/primitives/macro-panel.js`. The new component handles `macro:steps` messages instead of `macro:tree`, renders a step list on the left and a detail pane on the right, with prev/next navigation.

```js
// primitives/macro-panel.js — hm-macro-panel
//
// Displays macro expansion steps with two views:
// - Stepper: flat list of expansion steps with prev/next navigation
// - Tree: hierarchical view of expansion structure (added in a later task)
// Right pane: before/after with foci highlighting, pattern section.

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

    .toolbar button.active {
      background: var(--accent-bg, #E3F2FD);
      border-color: var(--accent, #007ACC);
      color: var(--accent, #007ACC);
    }

    .toolbar button:disabled {
      opacity: 0.4;
      cursor: default;
    }

    .step-counter {
      font-size: 12px;
      color: var(--fg-secondary, #616161);
      margin-left: auto;
    }

    .content {
      display: flex;
      flex: 1;
      overflow: hidden;
    }

    .step-list {
      width: 40%;
      min-width: 200px;
      overflow: auto;
      border-right: 1px solid var(--border, #D4D4D4);
    }

    .step-item {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      cursor: pointer;
      font-family: var(--font-editor, "SF Mono", Menlo, monospace);
      font-size: 12px;
      font-weight: var(--font-editor-weight, 300);
      border-bottom: 1px solid var(--border-light, #EEEEEE);
    }

    .step-item:hover {
      background: var(--bg-tab-hover, #F0F0F0);
    }

    .step-item.selected {
      background: var(--accent-bg, #E3F2FD);
      color: var(--accent, #007ACC);
    }

    .step-num {
      color: var(--fg-muted, #999999);
      font-size: 11px;
      min-width: 24px;
    }

    .step-type {
      font-size: 10px;
      padding: 1px 4px;
      border-radius: 2px;
      background: var(--bg-panel, #F5F5F5);
      color: var(--fg-muted, #999999);
    }

    .step-type.macro {
      background: #E3F2FD;
      color: #1565C0;
    }

    .step-macro {
      color: var(--accent, #007ACC);
      font-weight: 500;
    }

    .detail-pane {
      flex: 1;
      overflow: auto;
      padding: 8px 12px;
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
      margin-bottom: 8px;
    }

    .info-label {
      color: var(--fg-muted, #999999);
    }

    .macro-name {
      color: var(--accent, #007ACC);
      font-weight: 500;
    }

    .empty {
      color: var(--fg-muted, #999999);
      font-style: italic;
      padding: 20px;
      text-align: center;
    }

    .focus-highlight {
      background: #FFF9C4;
      border-radius: 2px;
      padding: 0 1px;
    }

    .focus-after-highlight {
      background: #C8E6C9;
      border-radius: 2px;
      padding: 0 1px;
    }

    .filter-select {
      font-size: 12px;
      border: 1px solid var(--border, #D4D4D4);
      border-radius: 3px;
      padding: 2px 4px;
      background: var(--bg-primary, #FFFFFF);
      font-family: inherit;
    }

    .pattern-section {
      padding: 8px;
      background: #E8F5E9;
      border: 1px solid #A5D6A7;
      border-radius: 4px;
      font-family: var(--font-editor, "SF Mono", Menlo, monospace);
      font-size: 12px;
    }

    .pattern-source {
      font-size: 11px;
      color: var(--fg-muted, #999999);
      margin-top: 4px;
    }
  `;

  constructor() {
    super();
    this._steps = [];
    this._currentIndex = -1;
    this._unsubs = [];
    this._error = null;
    this._filter = 'all'; // 'all' | 'macro'
    this._patterns = new Map(); // stepId -> pattern data
  }

  get _filteredSteps() {
    if (this._filter === 'macro') {
      return this._steps.filter(s => s.type === 'macro');
    }
    return this._steps;
  }

  get _currentStep() {
    const steps = this._filteredSteps;
    if (this._currentIndex >= 0 && this._currentIndex < steps.length) {
      return steps[this._currentIndex];
    }
    return null;
  }

  firstUpdated() {
    setTimeout(() => {
      this._unsubs.push(
        onMessage('macro:steps', (msg) => {
          this._steps = msg.steps || [];
          this._currentIndex = this._steps.length > 0 ? 0 : -1;
          this._error = null;
          this._patterns.clear();
          this.requestUpdate();
        }),
        onMessage('macro:pattern', (msg) => {
          if (msg.stepId) {
            this._patterns.set(msg.stepId, msg);
          }
          this.requestUpdate();
        }),
        onMessage('macro:error', (msg) => {
          this._error = msg.error || 'Unknown error';
          this._steps = [];
          this._currentIndex = -1;
          this.requestUpdate();
        }),
        onMessage('macro:clear', () => {
          this._steps = [];
          this._currentIndex = -1;
          this._error = null;
          this._patterns.clear();
          this.requestUpdate();
        })
      );
    }, 0);

    // Keyboard navigation
    this.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
        e.preventDefault();
        this._prevStep();
      } else if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
        e.preventDefault();
        this._nextStep();
      }
    });

    // Make focusable for keyboard events
    if (!this.hasAttribute('tabindex')) {
      this.setAttribute('tabindex', '0');
    }
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    for (const u of this._unsubs) u();
  }

  _prevStep() {
    if (this._currentIndex > 0) {
      this._currentIndex--;
      this.requestUpdate();
    }
  }

  _nextStep() {
    const steps = this._filteredSteps;
    if (this._currentIndex < steps.length - 1) {
      this._currentIndex++;
      this.requestUpdate();
    }
  }

  _selectStep(index) {
    this._currentIndex = index;
    this.requestUpdate();
  }

  _setFilter(filter) {
    this._filter = filter;
    this._currentIndex = this._filteredSteps.length > 0 ? 0 : -1;
    this.requestUpdate();
  }

  _renderStepItem(step, index) {
    const isSelected = index === this._currentIndex;
    const isMacro = step.type === 'macro';

    return html`
      <div class="step-item ${isSelected ? 'selected' : ''}"
           @click=${() => this._selectStep(index)}>
        <span class="step-num">${index + 1}</span>
        <span class="step-type ${isMacro ? 'macro' : ''}">${step.type}</span>
        ${step.macro ? html`<span class="step-macro">${step.macro}</span>` : ''}
      </div>
    `;
  }

  _renderDetail() {
    const step = this._currentStep;
    if (!step) {
      return html`<div class="empty">Select a step to view details</div>`;
    }

    const pattern = this._patterns.get(step.id);

    return html`
      <div class="info-row">
        <span class="info-label">Step:</span>
        <span>${step.typeLabel || step.type}</span>
        ${step.macro ? html`
          <span class="info-label" style="margin-left: 8px">Macro:</span>
          <span class="macro-name">${step.macro}</span>
        ` : ''}
      </div>

      <div class="detail-section">
        <div class="detail-label">Before</div>
        <div class="code-block">${step.before || '(empty)'}</div>
      </div>

      <div class="detail-section">
        <div class="detail-label">After</div>
        <div class="code-block">${step.after || '(empty)'}</div>
      </div>

      ${pattern ? html`
        <div class="detail-section">
          <div class="detail-label">Pattern</div>
          <div class="pattern-section">
            <div>${pattern.pattern}</div>
            ${pattern.source ? html`
              <div class="pattern-source">from: ${pattern.source}</div>
            ` : ''}
          </div>
        </div>
      ` : ''}
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

    if (this._steps.length === 0) {
      return html`
        <div class="toolbar">
          <span style="color: var(--fg-muted, #999); font-size: 12px;">
            Use Expand Macros (Cmd+Shift+E) to view macro expansions
          </span>
        </div>
        <div class="empty">No expansion data. Open a Racket file and click Expand Macros.</div>
      `;
    }

    const steps = this._filteredSteps;
    const total = steps.length;
    const current = this._currentIndex + 1;

    return html`
      <div class="toolbar">
        <button @click=${() => this._prevStep()}
                ?disabled=${this._currentIndex <= 0}>◀ Prev</button>
        <button @click=${() => this._nextStep()}
                ?disabled=${this._currentIndex >= total - 1}>Next ▶</button>
        <select class="filter-select"
                @change=${(e) => this._setFilter(e.target.value)}>
          <option value="all" ?selected=${this._filter === 'all'}>All steps</option>
          <option value="macro" ?selected=${this._filter === 'macro'}>Macro only</option>
        </select>
        <span class="step-counter">Step ${current} of ${total}</span>
        <button @click=${() => dispatch('macro:stop')}>Clear</button>
      </div>
      <div class="content">
        <div class="step-list">
          ${steps.map((s, i) => this._renderStepItem(s, i))}
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

### Step 2: Test manually via debug harness

Run: `cargo tauri dev`
Steps:
1. Open a `.rkt` file with macros (e.g., `cond`, `when`)
2. Press Cmd+Shift+E or click "Expand Macros"
3. Verify the MACROS tab shows a step list on the left
4. Click steps — detail pane should show before/after
5. Use Prev/Next buttons — should navigate steps
6. Change filter to "Macro only" — should hide tag/rename steps
7. Click Clear — should reset

### Step 3: Commit

```bash
git add frontend/core/primitives/macro-panel.js
git commit -m "feat: rewrite macro panel with stepper view and step navigation

New UI: step list on left, detail pane on right. Supports prev/next
navigation, macro-only filter, and keyboard arrows. Handles macro:steps
messages from the rewritten expansion engine."
```

---

## Task 4: Add the tree view toggle

**Files:**
- Modify: `racket/heavymental-core/macro-expander.rkt` (add tree building from derivation)
- Modify: `frontend/core/primitives/macro-panel.js` (add tree view + toggle)
- Modify: `test/test-macro-expander.rkt` (add tree tests)

### Step 1: Write failing test for macro:tree message

Add to `test/test-macro-expander.rkt`:

```racket
(test-case "start-macro-expander emits macro:tree alongside macro:steps"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))

  ;; Should have both macro:steps and macro:tree
  (check-not-false (find-message-by-type msgs "macro:steps"))
  (check-not-false (find-message-by-type msgs "macro:tree"))

  (define tree-msg (find-message-by-type msgs "macro:tree"))
  (define forms (hash-ref tree-msg 'forms))
  (check-true (list? forms))
  (check-true (> (length forms) 0))

  ;; Each tree node should have id, macro, label, children
  (define first-form (car forms))
  (check-true (hash-has-key? first-form 'id))
  (check-true (hash-has-key? first-form 'label))
  (check-true (hash-has-key? first-form 'children))

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))
```

### Step 2: Run test to verify it fails

Run: `racket test/test-macro-expander.rkt`
Expected: FAIL — no `macro:tree` message emitted yet

### Step 3: Add tree building to macro-expander.rkt

Add a `deriv->tree` function that walks the derivation tree (from `trace/result`) and builds a simplified tree structure. Add this after the step serialization code:

```racket
;; ── Tree building from derivation ────────────────────────────

(define _tree-counter 0)

(define (next-tree-id!)
  (set! _tree-counter (add1 _tree-counter))
  (format "node-~a" (sub1 _tree-counter)))

;; Walk a derivation and build a simplified tree of macro applications
(define (deriv->tree d)
  (cond
    [(mrule? d)
     (define id (next-tree-id!))
     (define resolves (base-resolves d))
     (define macro-name
       (if (and (pair? resolves) (identifier? (car resolves)))
           (symbol->string (syntax-e (car resolves)))
           #f))
     (define before-str (syntax->string (node-z1 d)))
     (define label (if (> (string-length before-str) 50)
                       (string-append (substring before-str 0 50) "...")
                       before-str))
     ;; Recurse into the next derivation
     (define child (deriv->tree (mrule-next d)))
     (define children (if child (list child) (list)))
     (hasheq 'id id
             'macro macro-name
             'label label
             'children (filter values children))]
    [(ecte? d)
     ;; Walk into the second derivation (after compile-time evals)
     (deriv->tree (ecte-second d))]
    [(p:if? d)
     ;; Walk test, then, else branches
     (define kids
       (filter values
               (list (deriv->tree (p:if-test d))
                     (deriv->tree (p:if-then d))
                     (deriv->tree (p:if-else d)))))
     (if (null? kids) #f
         (let ([id (next-tree-id!)])
           (hasheq 'id id
                   'macro #f
                   'label "if"
                   'children kids)))]
    [(tagrule? d)
     (deriv->tree (tagrule-next d))]
    [(p:stop? d) #f]
    [(p:#%datum? d) #f]
    [(p:let-values? d) #f]
    [else #f]))
```

Then in `start-macro-expander`, after building steps, add:

```racket
;; Build tree from derivation
(set! _tree-counter 0)
(define tree-forms
  (filter values
          (for/list ([form (in-list forms)])
            (with-handlers ([exn:fail? (lambda (e) #f)])
              (define-values (result deriv) (trace/result form))
              (deriv->tree deriv)))))
(send-message! (make-message "macro:tree" 'forms tree-forms))
```

**Important**: This means `trace/result` is called twice per form (once for steps, once for tree). To avoid this, refactor to call `trace/result` once and pass both the derivation and the reductions. This is a performance optimization that should be done in this step.

### Step 4: Add tree view toggle to frontend

In `macro-panel.js`, add:
- A `_view` property: `'stepper'` or `'tree'` (default: `'stepper'`)
- Toggle buttons in the toolbar
- Tree rendering (similar to the original `_renderNode` but using the new tree format)
- The detail pane is shared between both views

Add to the constructor:

```js
this._view = 'stepper'; // 'stepper' | 'tree'
this._treeNodes = [];
this._expandedNodes = new Set();
this._selectedTreeNode = null;
```

Add `macro:tree` handler in `firstUpdated()`:

```js
onMessage('macro:tree', (msg) => {
  this._treeNodes = msg.forms || [];
  // Auto-expand first level
  for (const f of this._treeNodes) {
    if (f.macro) this._expandedNodes.add(f.id);
  }
  this.requestUpdate();
}),
```

Add tree rendering methods (similar to original but adapted for new node format). Update the toolbar to include view toggle buttons. Update `render()` to switch between step list and tree based on `_view`.

### Step 5: Run tests and test manually

Run: `racket test/test-macro-expander.rkt`
Expected: PASS

Manual test: Toggle between Tree and Stepper views in the macro panel.

### Step 6: Commit

```bash
git add racket/heavymental-core/macro-expander.rkt frontend/core/primitives/macro-panel.js test/test-macro-expander.rkt
git commit -m "feat: add tree view with toggle alongside stepper view

Macro panel now supports two views: Tree (hierarchical) and Stepper
(flat step list). Toggle via toolbar buttons. Both share the same
detail pane. Tree built from macro-debugger derivation structure."
```

---

## Task 5: Add foci highlighting to detail view

**Files:**
- Modify: `frontend/core/primitives/macro-panel.js`

### Step 1: Implement foci highlighting in code blocks

The detail pane's before/after code blocks should highlight sub-expressions identified by `foci` and `fociAfter` data.

Add a method to `HmMacroPanel`:

```js
_renderCodeWithFoci(text, foci, highlightClass) {
  if (!foci || foci.length === 0) {
    return html`<div class="code-block">${text}</div>`;
  }

  // Sort foci by offset descending so we can insert spans without
  // shifting positions
  const sorted = [...foci]
    .filter(f => f.offset != null && f.span != null)
    .sort((a, b) => a.offset - b.offset);

  if (sorted.length === 0) {
    return html`<div class="code-block">${text}</div>`;
  }

  // Build segments: alternating plain text and highlighted spans
  const parts = [];
  let pos = 0;
  for (const f of sorted) {
    // Foci offsets are 1-based source positions from the original file.
    // We need to map them relative to the text string.
    // For now, use them directly since 'before' is the pretty-printed
    // form, not the original source. We'll highlight the full text
    // as a single focus if offsets don't map cleanly.
    if (f.offset > pos) {
      parts.push(text.substring(pos, f.offset));
    }
    parts.push(html`<span class="${highlightClass}">${text.substring(f.offset, f.offset + f.span)}</span>`);
    pos = f.offset + f.span;
  }
  if (pos < text.length) {
    parts.push(text.substring(pos));
  }

  return html`<div class="code-block">${parts}</div>`;
}
```

**Note:** Foci positions are from the original source syntax, but `before`/`after` text is pretty-printed from `syntax->datum`. The positions won't map directly. Two options:

A. Send the original source text alongside the pretty-printed version
B. Highlight the entire before/after as a single focus (simpler, less useful)

**Recommended:** Option A — add an `originalBefore` field from the Racket side that preserves the original source text with correct positions. This requires a small change to `step->json` in `macro-expander.rkt`.

### Step 2: Update step serialization to include original source text

In `macro-expander.rkt`, modify `step->json` to add:

```racket
;; Get original source text if source location is available
(define original-before
  (let ([pos (syntax-position before-stx)]
        [spn (syntax-span before-stx)]
        [src (syntax-source before-stx)])
    (if (and pos spn (path? src) (file-exists? src))
        (with-handlers ([exn:fail? (lambda (e) #f)])
          (define text (file->string src))
          (substring text (sub1 pos) (+ (sub1 pos) spn)))
        #f)))
```

Add `'originalBefore original-before` to the hasheq.

### Step 3: Update frontend to use foci with original text

In `_renderDetail()`, replace the plain before/after code blocks with `_renderCodeWithFoci()` calls:

```js
// In _renderDetail():
const beforeText = step.originalBefore || step.before;
const afterText = step.after;

// Before section
html`
  <div class="detail-section">
    <div class="detail-label">Before</div>
    ${this._renderCodeWithFoci(beforeText, step.foci, 'focus-highlight')}
  </div>
`

// After section
html`
  <div class="detail-section">
    <div class="detail-label">After</div>
    ${this._renderCodeWithFoci(afterText, step.fociAfter, 'focus-after-highlight')}
  </div>
`
```

### Step 4: Test manually

Run: `cargo tauri dev`
1. Open a file with `cond` or `when` macros
2. Expand Macros
3. Check that sub-expressions in the before/after blocks are highlighted
4. Yellow for before foci, green for after foci

### Step 5: Commit

```bash
git add racket/heavymental-core/macro-expander.rkt frontend/core/primitives/macro-panel.js
git commit -m "feat: add foci highlighting in before/after code blocks

Highlight changed sub-expressions using macro-debugger foci data.
Yellow for before-state foci, green for after-state foci. Falls back
to plain text when foci positions don't map cleanly."
```

---

## Task 6: Create pattern extractor module

**Files:**
- Create: `racket/heavymental-core/pattern-extractor.rkt`
- Create: `test/test-pattern-extractor.rkt`
- Modify: `racket/heavymental-core/macro-expander.rkt` (wire in)

### Step 1: Write failing tests for pattern extraction

Create `test/test-pattern-extractor.rkt`:

```racket
#lang racket/base

(require rackunit
         racket/file
         racket/port
         "../racket/heavymental-core/pattern-extractor.rkt")

;; ── Helpers ──────────────────────────────────────────────────────────────────

(define (make-temp-rkt-file content)
  (define tmp (make-temporary-file "pattern-test-~a.rkt"))
  (call-with-output-file tmp
    (lambda (out) (display content out))
    #:exists 'replace)
  tmp)

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: extract pattern from define-syntax-parse-rule
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "extract-pattern finds define-syntax-parse-rule pattern"
  (define tmp (make-temp-rkt-file
    (string-append
      "#lang racket/base\n"
      "(require syntax/parse/define)\n"
      "(define-syntax-parse-rule (my-if cond:expr then:expr else:expr)\n"
      "  (if cond then else))\n")))
  (define result (extract-pattern "my-if" (path->string tmp)))
  (check-not-false result "should find pattern for my-if")
  (check-true (hash-has-key? result 'pattern) "result should have 'pattern")
  (check-true (hash-has-key? result 'variables) "result should have 'variables")
  (check-true (string-contains? (hash-ref result 'pattern) "cond:expr")
              "pattern should contain 'cond:expr'")
  (delete-file tmp))

(test-case "extract-pattern returns #f for unknown macro"
  (define tmp (make-temp-rkt-file
    (string-append
      "#lang racket/base\n"
      "(require syntax/parse/define)\n"
      "(define-syntax-parse-rule (my-if cond:expr then:expr else:expr)\n"
      "  (if cond then else))\n")))
  (define result (extract-pattern "not-a-macro" (path->string tmp)))
  (check-false result "should return #f for unknown macro")
  (delete-file tmp))

(test-case "extract-pattern handles define-simple-macro"
  (define tmp (make-temp-rkt-file
    (string-append
      "#lang racket/base\n"
      "(require (for-syntax racket/base))\n"
      "(define-syntax-rule (swap! a b)\n"
      "  (let ([tmp a]) (set! a b) (set! b tmp)))\n")))
  (define result (extract-pattern "swap!" (path->string tmp)))
  (check-not-false result "should find pattern for swap!")
  (check-true (string-contains? (hash-ref result 'pattern) "swap!")
              "pattern should contain 'swap!'")
  (delete-file tmp))

(test-case "extract-pattern returns #f for non-existent file"
  (define result (extract-pattern "foo" "/nonexistent/file.rkt"))
  (check-false result))

(test-case "extract-pattern extracts variable names"
  (define tmp (make-temp-rkt-file
    (string-append
      "#lang racket/base\n"
      "(require syntax/parse/define)\n"
      "(define-syntax-parse-rule (my-when test:expr body:expr ...)\n"
      "  (if test (begin body ...) (void)))\n")))
  (define result (extract-pattern "my-when" (path->string tmp)))
  (check-not-false result)
  (define vars (hash-ref result 'variables '()))
  (check-true (> (length vars) 0) "should have pattern variables")
  ;; Check variable names include test and body
  (define var-names (map (lambda (v) (hash-ref v 'name)) vars))
  (check-true (member "test" var-names) "should include 'test' variable")
  (check-true (member "body" var-names) "should include 'body' variable")
  (delete-file tmp))

(displayln "All pattern extractor tests passed!")
```

### Step 2: Run tests to verify they fail

Run: `racket test/test-pattern-extractor.rkt`
Expected: FAIL — module doesn't exist yet

### Step 3: Implement pattern-extractor.rkt

Create `racket/heavymental-core/pattern-extractor.rkt`:

```racket
#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/port
         racket/string)

(provide extract-pattern)

;; extract-pattern: Given a macro name and a file path, try to find
;; the macro's definition and extract its syntax-parse pattern.
;;
;; Returns: hasheq with 'pattern (string) and 'variables (list of hasheq)
;;          or #f if not found.
(define (extract-pattern macro-name file-path)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (unless (and (string? file-path) (file-exists? file-path))
      (error "file not found"))

    (define text (file->string file-path))
    (define port (open-input-string text))

    ;; Read all S-expressions, looking for the macro definition
    (let loop ()
      (define form (with-handlers ([exn:fail? (lambda (e) eof)]) (read port)))
      (cond
        [(eof-object? form) #f]
        [(match-define-syntax-parse-rule form macro-name)
         => values]
        [(match-define-syntax-rule form macro-name)
         => values]
        [else (loop)]))))

;; Try to match a (define-syntax-parse-rule (name pattern ...) template ...) form
(define (match-define-syntax-parse-rule form macro-name)
  (match form
    [`(define-syntax-parse-rule (,(? symbol? name) . ,pattern-parts) . ,_)
     #:when (string=? (symbol->string name) macro-name)
     (define pattern-str (format "(~a ~a)"
                                 name
                                 (string-join (map ~a pattern-parts) " ")))
     (define vars (extract-variables pattern-parts))
     (hasheq 'pattern pattern-str
             'variables vars
             'source #f)]
    [_ #f]))

;; Try to match a (define-syntax-rule (name pattern ...) template ...) form
(define (match-define-syntax-rule form macro-name)
  (match form
    [`(define-syntax-rule (,(? symbol? name) . ,pattern-parts) . ,_)
     #:when (string=? (symbol->string name) macro-name)
     (define pattern-str (format "(~a ~a)"
                                 name
                                 (string-join (map ~a pattern-parts) " ")))
     (define vars (extract-variables pattern-parts))
     (hasheq 'pattern pattern-str
             'variables vars
             'source #f)]
    [_ #f]))

;; Extract variable names from pattern parts.
;; Handles: plain identifiers (x), annotated (x:expr), ellipsis patterns (x ...)
(define (extract-variables parts)
  (define colors '("#4CAF50" "#2196F3" "#FF9800" "#E91E63" "#9C27B0"
                   "#00BCD4" "#FF5722" "#795548"))
  (define var-list
    (let loop ([parts parts] [acc '()])
      (cond
        [(null? parts) (reverse acc)]
        [(symbol? (car parts))
         (define name-str (symbol->string (car parts)))
         (cond
           ;; Skip ellipsis and underscore
           [(member name-str '("..." "___" "_")) (loop (cdr parts) acc)]
           ;; Annotated: name:class
           [(string-contains? name-str ":")
            (define var-name (car (string-split name-str ":")))
            (loop (cdr parts) (cons var-name acc))]
           ;; Plain identifier
           [else (loop (cdr parts) (cons name-str acc))])]
        [(pair? (car parts))
         ;; Recurse into sub-patterns
         (loop (cdr parts) (append (reverse (map (lambda (v) (hash-ref v 'name))
                                                  (extract-variables (car parts))))
                                    acc))]
        [else (loop (cdr parts) acc)])))

  (for/list ([name (in-list var-list)]
             [i (in-naturals)])
    (hasheq 'name name
            'color (list-ref colors (modulo i (length colors))))))

;; Helper: convert any value to string
(define (~a v)
  (format "~a" v))
```

### Step 4: Run tests

Run: `racket test/test-pattern-extractor.rkt`
Expected: PASS (may need debugging — the S-expression reader reads after `#lang` which is not standard `read`; may need to skip the `#lang` line first)

**Fix if needed:** Skip lines starting with `#lang` before reading:

```racket
;; Skip #lang line
(define (skip-lang-line port)
  (define line (read-line port))
  (when (and (string? line) (not (string-prefix? line "#lang")))
    ;; Put it back — actually can't put back, so re-read from adjusted position
    (void)))
```

Or better: read the file as a string, strip lines starting with `#lang`, then read from the remaining string.

### Step 5: Commit

```bash
git add racket/heavymental-core/pattern-extractor.rkt test/test-pattern-extractor.rkt
git commit -m "feat: pattern extractor for syntax-parse macro definitions

Reads macro source files, finds define-syntax-parse-rule or
define-syntax-rule forms, extracts pattern text and variable names.
Returns structured data for frontend highlighting."
```

---

## Task 7: Wire pattern extractor into expansion pipeline

**Files:**
- Modify: `racket/heavymental-core/macro-expander.rkt`
- Modify: `test/test-macro-expander.rkt`

### Step 1: Write failing test

Add to `test/test-macro-expander.rkt`:

```racket
(test-case "macro:pattern emitted for syntax-parse macros"
  (reset-state!)
  ;; Create a file that defines and uses a syntax-parse macro
  (define macro-file (make-temp-rkt-file
    (string-append
      "#lang racket/base\n"
      "(require syntax/parse/define)\n"
      "(define-syntax-parse-rule (my-when test:expr body:expr ...)\n"
      "  (if test (begin body ...) (void)))\n"
      "(my-when #t (displayln \"hi\"))\n")))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string macro-file)))))
  (define msgs (parse-all-messages output))

  ;; Should have a macro:pattern message
  (define pattern-msgs (find-all-messages-by-type msgs "macro:pattern"))
  (check-true (> (length pattern-msgs) 0) "should emit at least one macro:pattern")

  (define first-pattern (car pattern-msgs))
  (check-true (hash-has-key? first-pattern 'pattern))
  (check-true (hash-has-key? first-pattern 'variables))
  (check-true (string-contains? (hash-ref first-pattern 'pattern) "my-when"))

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file macro-file))
```

### Step 2: Run test to verify it fails

Run: `racket test/test-macro-expander.rkt`
Expected: FAIL

### Step 3: Wire pattern extractor into start-macro-expander

In `macro-expander.rkt`, add:

```racket
(require "pattern-extractor.rkt")
```

After serializing steps, iterate macro steps and attempt pattern extraction:

```racket
;; Attempt pattern extraction for macro steps
(for ([step-json (in-list step-jsons)])
  (when (string=? (hash-ref step-json 'type) "macro")
    (define macro-name (hash-ref step-json 'macro #f))
    (when macro-name
      ;; Try to extract pattern from the source file being expanded
      (define pattern-info (extract-pattern macro-name path))
      (when pattern-info
        (send-message!
          (make-message "macro:pattern"
                        'stepId (hash-ref step-json 'id)
                        'pattern (hash-ref pattern-info 'pattern)
                        'variables (hash-ref pattern-info 'variables)
                        'source (format "~a" path)))))))
```

### Step 4: Run tests

Run: `racket test/test-macro-expander.rkt`
Expected: PASS

### Step 5: Commit

```bash
git add racket/heavymental-core/macro-expander.rkt test/test-macro-expander.rkt
git commit -m "feat: wire pattern extractor into expansion pipeline

For macro steps where the macro is defined with syntax-parse in the
current file, extract and emit pattern data via macro:pattern messages."
```

---

## Task 8: Add keyboard navigation and polish

**Files:**
- Modify: `frontend/core/primitives/macro-panel.js`

### Step 1: Add keyboard shortcuts

The keyboard handler is already set up in Task 3. Ensure it works:
- Left/Up arrow: previous step
- Right/Down arrow: next step
- Escape: clear expansion data

### Step 2: Scroll selected step into view

In `_selectStep()` and `_prevStep()`/`_nextStep()`, after updating state, scroll the selected step item into view:

```js
updated() {
  // Scroll selected step into view
  const selected = this.shadowRoot?.querySelector('.step-item.selected');
  if (selected) {
    selected.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }
}
```

### Step 3: Test manually

Run: `cargo tauri dev`
1. Expand macros, use arrow keys to navigate
2. Verify scroll follows selection
3. Verify Escape clears

### Step 4: Commit

```bash
git add frontend/core/primitives/macro-panel.js
git commit -m "fix: keyboard navigation and scroll-into-view for macro stepper"
```

---

## Task 9: Integration test and final polish

**Files:**
- Modify: `test/test-macro-expander.rkt` (any remaining test fixes)
- Modify: `racket/heavymental-core/macro-expander.rkt` (edge cases)

### Step 1: Run all Racket tests

```bash
racket test/test-macro-expander.rkt
racket test/test-pattern-extractor.rkt
racket test/test-bridge.rkt
racket test/test-phase2.rkt
racket test/test-lang-intel.rkt
```

All should pass. Fix any regressions.

### Step 2: Full manual test via debug harness

1. `cargo tauri dev`
2. Open various Racket files:
   - File with `cond`, `when`, `match` (built-in macros)
   - File with `define-syntax-parse-rule` macros (pattern extraction)
   - File with syntax errors (error handling)
   - Empty file
3. For each: Expand Macros → verify step list, tree view toggle, detail view, foci, patterns
4. Test prev/next, filter, clear, keyboard navigation
5. Test expand → clear → expand again

### Step 3: Fix any issues found

Address edge cases:
- Very large files (many expansion steps)
- Macros from required libraries (pattern extraction won't work — should silently skip)
- Files without `#lang` line

### Step 4: Commit

```bash
git add -A
git commit -m "test: integration tests and edge case fixes for Phase B"
```

---

## Summary

| Task | Description | Key files |
|------|-------------|-----------|
| 1 | Rewrite engine with macro-debugger | `macro-expander.rkt`, `test-macro-expander.rkt` |
| 2 | Add macro-only filter | `macro-expander.rkt` |
| 3 | Build stepper view frontend | `macro-panel.js` |
| 4 | Add tree view toggle | `macro-expander.rkt`, `macro-panel.js` |
| 5 | Add foci highlighting | `macro-panel.js`, `macro-expander.rkt` |
| 6 | Create pattern extractor | `pattern-extractor.rkt`, `test-pattern-extractor.rkt` |
| 7 | Wire pattern extractor | `macro-expander.rkt` |
| 8 | Keyboard navigation + polish | `macro-panel.js` |
| 9 | Integration test | all |
