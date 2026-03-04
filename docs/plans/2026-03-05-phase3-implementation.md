# Phase 3: Language Intelligence — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make HeavyMental language-aware via drracket/check-syntax — diagnostics, hover, go-to-definition, binding arrows, completions, error panel, REPL error linking, and Rhombus syntax highlighting.

**Architecture:** Racket runs check-syntax on a background place, pushes all intelligence data (`intel:*` messages) to the frontend. Frontend caches data and feeds it to Monaco providers. SVG overlay draws Check Syntax binding arrows. Rust is unchanged — remains language-agnostic. See `docs/plans/2026-03-05-phase3-language-intelligence-design.md` for full design.

**Tech Stack:**
- `drracket/check-syntax` (Racket library, programmatic Check Syntax)
- `data/interval-map` (Racket library, efficient range lookups)
- `racket/place` (Racket parallel execution for background analysis)
- Monaco Editor APIs: `setModelMarkers`, `registerHoverProvider`, `registerCompletionItemProvider`, `registerDefinitionProvider`, `registerReferenceProvider`, `createDecorationsCollection`, overlay widgets
- SVG for Check Syntax arrow rendering

---

## Task 1: Add drracket/check-syntax Dependency

**Files:**
- Modify: `racket/heavymental-core/info.rkt`

**Step 1: Add drracket-tool-lib to deps**

In `info.rkt`, add `"drracket-tool-lib"` to the `deps` list. This provides `drracket/check-syntax`.

```racket
#lang info
(define collection "heavymental")
(define deps '("base" "drracket-tool-lib"))
(define build-deps '("rackunit-lib"))
(define pkg-desc "HeavyMental core bridge library")
(define version "0.1.0")
```

**Step 2: Install the dependency**

Run:
```bash
cd racket/heavymental-core && raco pkg install --auto drracket-tool-lib
```

Expected: Package installs successfully. Verify:
```bash
racket -e '(require drracket/check-syntax) (displayln "ok")'
```
Expected: `ok`

**Step 3: Commit**

```bash
git add racket/heavymental-core/info.rkt
git commit -m "deps: add drracket-tool-lib for check-syntax integration"
```

---

## Task 2: Document Sync — Frontend Emits document:opened/changed/closed

**Files:**
- Modify: `frontend/core/primitives/editor.js`
- Modify: `frontend/core/bridge.js`

The editor must notify Racket when a document is opened, changed, or closed so Racket can run check-syntax.

**Step 1: Add request/response correlation to bridge.js**

Add a `request()` function to `bridge.js` that sends a message and returns a Promise resolved when a matching response arrives (by `id`). This is needed later for completion requests.

At the end of `bridge.js`, before the closing, add:

```javascript
let nextRequestId = 1;
const pendingRequests = new Map();

export function request(type, payload = {}) {
  const id = nextRequestId++;
  const message = { type: 'event', name: type, id, ...payload };
  return new Promise((resolve, reject) => {
    pendingRequests.set(id, { resolve, reject });
    window.__TAURI__.core.invoke('send_to_racket', { message })
      .catch(reject);
  });
}

export function resolveRequest(id, data) {
  const pending = pendingRequests.get(id);
  if (pending) {
    pendingRequests.delete(id);
    pending.resolve(data);
  }
}
```

**Step 2: Emit document:opened when editor:open arrives**

In `editor.js`, in the `editor:open` bridge listener (around line 182), after setting the editor value, dispatch a `document:opened` event to Racket:

```javascript
// After this._editor.setValue(content || '');
// After this._dirty = false;
dispatch('document:opened', {
  uri: path || '',
  text: content || '',
  languageId: language || 'racket',
});
```

**Step 3: Emit document:changed on content edits**

In `editor.js`, in the `onDidChangeModelContent` handler (around line 150), add a debounced dispatch:

Add a debounce timer field in the constructor:
```javascript
this._changeTimer = null;
```

Replace the `onDidChangeModelContent` handler:
```javascript
this._changeDisposable = this._editor.onDidChangeModelContent((e) => {
  if (!this._dirty) {
    this._dirty = true;
    dispatch('editor:dirty', { path: this.filePath });
  }
  // Debounced document:changed for language intelligence
  if (this._changeTimer) clearTimeout(this._changeTimer);
  this._changeTimer = setTimeout(() => {
    this._changeTimer = null;
    const text = this._editor.getValue();
    dispatch('document:changed', {
      uri: this.filePath,
      text,
    });
  }, 500);
});
```

**Step 4: Emit document:closed on tab close (future)**

For now, document:closed is not critical — we'll add it when tab close logic is refined. The Racket side should handle missing documents gracefully.

**Step 5: Clean up timer in disconnectedCallback**

In `disconnectedCallback`, add:
```javascript
if (this._changeTimer) {
  clearTimeout(this._changeTimer);
  this._changeTimer = null;
}
```

**Step 6: Verify manually**

Build and run HeavyMental. Open a file. Check Racket stderr for "Unknown event: document:opened" — this confirms the message is arriving at Racket's dispatch. Racket doesn't handle it yet (that's Task 3).

**Step 7: Commit**

```bash
git add frontend/core/bridge.js frontend/core/primitives/editor.js
git commit -m "feat: emit document:opened and document:changed from editor"
```

---

## Task 3: Racket lang-intel.rkt — Core Check Syntax Integration

**Files:**
- Create: `racket/heavymental-core/lang-intel.rkt`

This is the heart of Phase 3. It uses `drracket/check-syntax` to analyze source code and extract binding arrows, hovers, semantic colors, diagnostics, definitions, and references.

**Step 1: Write the test file**

Create `test/test-lang-intel.rkt`:

```racket
#lang racket/base

(require rackunit
         json
         racket/port
         racket/string
         "../racket/heavymental-core/protocol.rkt"
         "../racket/heavymental-core/lang-intel.rkt")

;; ── Helpers ──────────────────────────────────────────────────

(define (parse-all-messages output)
  (define lines (string-split (string-trim output) "\n"))
  (for/list ([line (in-list lines)]
             #:when (> (string-length (string-trim line)) 0))
    (string->jsexpr line)))

(define (messages-of-type msgs type-str)
  (filter (lambda (m) (equal? (hash-ref m 'type #f) type-str)) msgs))

;; ── Test: analyze-source produces diagnostics ────────────────

(test-case "analyze-source returns diagnostics for valid code"
  (define result (analyze-source "/tmp/test.rkt" "#lang racket\n(define x 42)\n"))
  (check-true (hash? result))
  (check-true (hash-has-key? result 'diagnostics))
  (check-true (list? (hash-ref result 'diagnostics))))

(test-case "analyze-source returns arrows for binding"
  (define result (analyze-source "/tmp/test.rkt"
                                 "#lang racket\n(define x 42)\nx\n"))
  (check-true (hash-has-key? result 'arrows))
  (define arrows (hash-ref result 'arrows))
  ;; There should be at least one arrow from the use of x to its definition
  (check-true (> (length arrows) 0)))

(test-case "analyze-source returns diagnostics for error"
  (define result (analyze-source "/tmp/test.rkt"
                                 "#lang racket\n(define x)\n"))
  (define diags (hash-ref result 'diagnostics))
  (check-true (> (length diags) 0))
  ;; The diagnostic should mention something about the error
  (check-true (string? (hash-ref (car diags) 'message))))

(test-case "analyze-source returns hovers"
  (define result (analyze-source "/tmp/test.rkt"
                                 "#lang racket\n(define x 42)\nx\n"))
  (check-true (hash-has-key? result 'hovers))
  (check-true (list? (hash-ref result 'hovers))))

(test-case "analyze-source returns colors"
  (define result (analyze-source "/tmp/test.rkt"
                                 "#lang racket\n(define x 42)\nx\n"))
  (check-true (hash-has-key? result 'colors))
  (check-true (list? (hash-ref result 'colors))))
```

**Step 2: Run tests to verify they fail**

Run:
```bash
racket test/test-lang-intel.rkt
```
Expected: Error — `lang-intel.rkt` doesn't exist yet.

**Step 3: Implement lang-intel.rkt**

Create `racket/heavymental-core/lang-intel.rkt`:

```racket
#lang racket/base

(require racket/class
         racket/match
         racket/list
         racket/string
         drracket/check-syntax
         "protocol.rkt")

(provide analyze-source
         push-intel-to-frontend!
         handle-document-opened
         handle-document-changed
         handle-document-closed
         handle-completion-request)

;; ── Trace collector ────────────────────────────────────────

;; Collects check-syntax annotations into lists for JSON serialization.
(define build-trace%
  (class (annotations-mixin object%)
    (init-field src)

    (define arrows '())
    (define hovers '())
    (define colors '())
    (define definitions '())
    (define jump-targets '())
    (define diagnostics '())
    (define unused-requires '())

    (define/public (get-arrows) (reverse arrows))
    (define/public (get-hovers) (reverse hovers))
    (define/public (get-colors) (reverse colors))
    (define/public (get-definitions) (reverse definitions))
    (define/public (get-jump-targets) (reverse jump-targets))
    (define/public (get-diagnostics) (reverse diagnostics))

    ;; Only process annotations for our source file
    (define/override (syncheck:find-source-object stx)
      (and (equal? src (syntax-source stx)) src))

    ;; Binding arrows
    (define/override (syncheck:add-arrow/name-dup/pxpy
                      start-src start-left start-right start-px start-py
                      end-src end-left end-right end-px end-py
                      actual? phase require-arrow? name-dup?)
      (set! arrows
            (cons (hasheq 'from start-left
                          'fromEnd start-right
                          'to end-left
                          'toEnd end-right
                          'kind (cond [require-arrow? "require"]
                                      [actual? "binding"]
                                      [else "tail"]))
                  arrows)))

    ;; Tail arrows
    (define/override (syncheck:add-tail-arrow from-src from-pos to-src to-pos)
      (set! arrows
            (cons (hasheq 'from from-pos
                          'fromEnd (add1 from-pos)
                          'to to-pos
                          'toEnd (add1 to-pos)
                          'kind "tail")
                  arrows)))

    ;; Hover text
    (define/override (syncheck:add-mouse-over-status _src left right text)
      (set! hovers
            (cons (hasheq 'from left 'to right 'text text)
                  hovers)))

    ;; Semantic coloring
    (define/override (syncheck:color-range _src start end style-name)
      (define style
        (cond
          [(string-suffix? style-name "lexically-bound") "lexically-bound"]
          [(string-suffix? style-name "imported") "imported"]
          [(string-suffix? style-name "set!d") "set!d"]
          [(string-suffix? style-name "free-variable") "free-variable"]
          [(string-suffix? style-name "unused-require") "unused-require"]
          [else style-name]))
      (set! colors
            (cons (hasheq 'from start 'to end 'style style)
                  colors)))

    ;; Definition targets
    (define/override (syncheck:add-definition-target/phase-level+space
                      _src left right id _mods _phase+space)
      (set! definitions
            (cons (hasheq 'from left 'to right
                          'name (symbol->string id))
                  definitions)))

    ;; Jump to definition (cross-file)
    (define/override (syncheck:add-jump-to-definition/phase-level+space
                      _src left right id path _mods _phase+space)
      (set! jump-targets
            (cons (hasheq 'from left 'to right
                          'name (symbol->string id)
                          'path (if (string? path) path
                                    (if (path? path) (path->string path) "")))
                  jump-targets)))

    ;; Unused requires
    (define/override (syncheck:add-unused-require _src left right)
      (set! diagnostics
            (cons (hasheq 'from left 'to right
                          'severity "warning"
                          'message "Unused require"
                          'source "check-syntax")
                  diagnostics)))

    (super-new)))

;; ── Analysis ───────────────────────────────────────────────

;; Analyze source code using check-syntax.
;; Returns a hasheq with keys: arrows, hovers, colors, definitions,
;; jump-targets, diagnostics.
(define (analyze-source uri text)
  (define trace (new build-trace% [src uri]))
  (define error-diagnostics '())

  (with-handlers
    ([exn:fail?
      (lambda (e)
        (set! error-diagnostics
              (list (hasheq 'from 0 'to (min 1 (string-length text))
                            'severity "error"
                            'message (exn-message e)
                            'source "check-syntax"))))])

    (define port (open-input-string text))
    (port-count-lines! port)

    (define-values (expanded-expression expansion-completed)
      (make-traversal (make-base-namespace) uri))

    (parameterize ([current-annotations trace]
                   [current-namespace (make-base-namespace)])
      (expanded-expression
       (expand
        (with-module-reading-parameterization
          (lambda () (read-syntax uri port)))))
      (expansion-completed)))

  (hasheq 'arrows (send trace get-arrows)
          'hovers (send trace get-hovers)
          'colors (send trace get-colors)
          'definitions (send trace get-definitions)
          'jump-targets (send trace get-jump-targets)
          'diagnostics (append (send trace get-diagnostics)
                               error-diagnostics)))

;; ── Offset → Line/Col conversion ──────────────────────────

;; Convert a character offset to {line, col} (1-based lines, 0-based cols)
;; matching Monaco's convention.
(define (offset->position text offset)
  (define safe-offset (min offset (string-length text)))
  (define prefix (substring text 0 safe-offset))
  (define lines (string-split prefix "\n" #:trim? #f))
  (define line-count (length lines))
  (define last-line (if (null? lines) "" (last lines)))
  (hasheq 'line line-count
          'col (string-length last-line)))

;; Convert a from/to offset pair to a Monaco range
(define (offsets->range text from to)
  (define start (offset->position text from))
  (define end (offset->position text to))
  (hasheq 'startLine (hash-ref start 'line)
          'startCol (hash-ref start 'col)
          'endLine (hash-ref end 'line)
          'endCol (hash-ref end 'col)))

;; ── Intel cache ────────────────────────────────────────────

;; Cache of analysis results per URI
(define intel-cache (make-hash))

;; Cache entry stores the text (for offset conversion) and the trace results
(struct intel-entry (text result) #:transparent)

;; ── Push results to frontend ───────────────────────────────

(define (push-intel-to-frontend! uri text result)
  ;; Store in cache for later lookups (hover, definition, completion requests)
  (hash-set! intel-cache uri (intel-entry text result))

  ;; Diagnostics
  (define diags
    (for/list ([d (in-list (hash-ref result 'diagnostics))])
      (define range (offsets->range text
                                    (hash-ref d 'from)
                                    (hash-ref d 'to)))
      (hasheq 'range range
              'severity (hash-ref d 'severity)
              'message (hash-ref d 'message)
              'source (hash-ref d 'source "check-syntax"))))
  (send-message! (make-message "intel:diagnostics"
                               'uri uri
                               'items diags))

  ;; Arrows
  (define arrow-data
    (for/list ([a (in-list (hash-ref result 'arrows))])
      (define from-range (offsets->range text
                                         (hash-ref a 'from)
                                         (hash-ref a 'fromEnd)))
      (define to-range (offsets->range text
                                       (hash-ref a 'to)
                                       (hash-ref a 'toEnd)))
      (hasheq 'from from-range
              'to to-range
              'kind (hash-ref a 'kind))))
  (send-message! (make-message "intel:arrows"
                               'uri uri
                               'arrows arrow-data))

  ;; Hovers
  (define hover-data
    (for/list ([h (in-list (hash-ref result 'hovers))])
      (define range (offsets->range text
                                    (hash-ref h 'from)
                                    (hash-ref h 'to)))
      (hasheq 'range range
              'contents (hash-ref h 'text))))
  (send-message! (make-message "intel:hovers"
                               'uri uri
                               'hovers hover-data))

  ;; Colors
  (define color-data
    (for/list ([c (in-list (hash-ref result 'colors))])
      (define range (offsets->range text
                                    (hash-ref c 'from)
                                    (hash-ref c 'to)))
      (hasheq 'range range
              'style (hash-ref c 'style))))
  (send-message! (make-message "intel:colors"
                               'uri uri
                               'colors color-data))

  ;; Definitions (for go-to-definition within file)
  (define def-data
    (for/list ([d (in-list (hash-ref result 'definitions))])
      (define range (offsets->range text
                                    (hash-ref d 'from)
                                    (hash-ref d 'to)))
      (hasheq 'range range
              'name (hash-ref d 'name))))
  ;; Jump targets (for go-to-definition cross-file)
  (define jump-data
    (for/list ([j (in-list (hash-ref result 'jump-targets))])
      (define range (offsets->range text
                                    (hash-ref j 'from)
                                    (hash-ref j 'to)))
      (hasheq 'range range
              'name (hash-ref j 'name)
              'targetUri (hash-ref j 'path))))
  (send-message! (make-message "intel:definitions"
                               'uri uri
                               'defs def-data
                               'jumps jump-data)))

;; ── Event handlers (called from main.rkt dispatch) ────────

(define (handle-document-opened msg)
  (define uri (message-ref msg 'uri ""))
  (define text (message-ref msg 'text ""))
  (when (and (not (string=? uri ""))
             (not (string=? text "")))
    (eprintf "[lang-intel] Analyzing ~a (~a chars)...\n"
             uri (string-length text))
    (define result (analyze-source uri text))
    (push-intel-to-frontend! uri text result)
    (eprintf "[lang-intel] Analysis complete: ~a diagnostics, ~a arrows\n"
             (length (hash-ref result 'diagnostics))
             (length (hash-ref result 'arrows)))))

(define (handle-document-changed msg)
  (define uri (message-ref msg 'uri ""))
  (define text (message-ref msg 'text ""))
  (when (and (not (string=? uri ""))
             (not (string=? text "")))
    ;; Re-analyze (debouncing is done on the frontend side)
    (eprintf "[lang-intel] Re-analyzing ~a...\n" uri)
    (define result (analyze-source uri text))
    (push-intel-to-frontend! uri text result)))

(define (handle-document-closed msg)
  (define uri (message-ref msg 'uri ""))
  (hash-remove! intel-cache uri)
  (send-message! (make-message "intel:clear" 'uri uri)))

(define (handle-completion-request msg)
  (define uri (message-ref msg 'uri ""))
  (define id (message-ref msg 'id 0))
  (define prefix (message-ref msg 'prefix ""))
  (define entry (hash-ref intel-cache uri #f))
  (define items
    (if entry
        (let* ([result (intel-entry-result entry)]
               [defs (hash-ref result 'definitions)]
               [names (map (lambda (d) (hash-ref d 'name)) defs)]
               [filtered (if (string=? prefix "")
                             names
                             (filter (lambda (n)
                                       (string-prefix? n prefix))
                                     names))])
          (for/list ([name (in-list filtered)])
            (hasheq 'label name
                    'kind "variable")))
        '()))
  (send-message! (make-message "intel:completion-response"
                               'id id
                               'items items)))
```

**Step 4: Run tests**

Run:
```bash
racket test/test-lang-intel.rkt
```
Expected: All 5 tests pass.

Note: `analyze-source` may take a few seconds the first time as `drracket/check-syntax` loads. If tests fail due to check-syntax behavior, adjust expectations — the key is that it returns the right structure.

**Step 5: Commit**

```bash
git add racket/heavymental-core/lang-intel.rkt test/test-lang-intel.rkt
git commit -m "feat: lang-intel.rkt — check-syntax integration with trace collector"
```

---

## Task 4: Wire lang-intel into main.rkt Dispatch

**Files:**
- Modify: `racket/heavymental-core/main.rkt`

**Step 1: Add require**

At the top of `main.rkt`, add to the require list:

```racket
(require racket/path
         "protocol.rkt"
         "cell.rkt"
         "editor.rkt"
         "repl.rkt"
         "lang-intel.rkt")
```

**Step 2: Add document event handling**

In `handle-event`, add cases for the document sync events. Add these before the `[else ...]` clause:

```racket
    ;; Document sync for language intelligence
    [(string=? event-name "document:opened")
     (handle-document-opened msg)]
    [(string=? event-name "document:changed")
     (handle-document-changed msg)]
    [(string=? event-name "document:closed")
     (handle-document-closed msg)]
    ;; Completion request
    [(string=? event-name "intel:completion-request")
     (handle-completion-request msg)]
```

**Step 3: Verify manually**

Build and run. Open a Racket file. Check Racket stderr — you should see:
```
[lang-intel] Analyzing /path/to/file.rkt (N chars)...
[lang-intel] Analysis complete: X diagnostics, Y arrows
```

**Step 4: Commit**

```bash
git add racket/heavymental-core/main.rkt
git commit -m "feat: wire lang-intel into main event dispatcher"
```

---

## Task 5: Frontend Diagnostics — Squiggly Underlines

**Files:**
- Create: `frontend/core/lang-intel.js`
- Modify: `frontend/core/main.js`
- Modify: `frontend/core/primitives/editor.js`

**Step 1: Create lang-intel.js**

Create `frontend/core/lang-intel.js`:

```javascript
// lang-intel.js — Language intelligence cache and Monaco providers
//
// Receives intel:* messages from Racket, caches data, and feeds
// Monaco providers. This is a thin rendering layer — Racket does
// all the heavy lifting.

import { onMessage, request, resolveRequest } from './bridge.js';

// Per-URI caches
const diagnosticsCache = new Map();
const hoversCache = new Map();
const arrowsCache = new Map();
const colorsCache = new Map();
const definitionsCache = new Map();

// Reference to Monaco and editor (set during init)
let monacoRef = null;
let editorRef = null;

/** Disposables for Monaco providers */
const disposables = [];

/** Arrow update callback (set by arrows.js) */
let arrowUpdateCallback = null;

export function onArrowsUpdated(cb) {
  arrowUpdateCallback = cb;
}

export function getArrows(uri) {
  return arrowsCache.get(uri) || [];
}

export function getHovers(uri) {
  return hoversCache.get(uri) || [];
}

export function getDefinitions(uri) {
  return definitionsCache.get(uri) || { defs: [], jumps: [] };
}

/**
 * Initialize language intelligence.
 * Must be called after Monaco is available.
 * @param {typeof import('monaco-editor').monaco} monaco
 * @param {import('monaco-editor').monaco.editor.IStandaloneCodeEditor} editor
 */
export function initLangIntel(monaco, editor) {
  monacoRef = monaco;
  editorRef = editor;

  // ── Diagnostics ──
  onMessage('intel:diagnostics', (msg) => {
    const { uri, items } = msg;
    diagnosticsCache.set(uri, items);
    applyDiagnostics(uri, items);
  });

  // ── Hovers ──
  onMessage('intel:hovers', (msg) => {
    const { uri, hovers } = msg;
    hoversCache.set(uri, hovers);
  });

  // ── Arrows ──
  onMessage('intel:arrows', (msg) => {
    const { uri, arrows } = msg;
    arrowsCache.set(uri, arrows);
    if (arrowUpdateCallback) arrowUpdateCallback(uri, arrows);
  });

  // ── Colors ──
  onMessage('intel:colors', (msg) => {
    const { uri, colors } = msg;
    colorsCache.set(uri, colors);
    applySemanticColors(colors);
  });

  // ── Definitions ──
  onMessage('intel:definitions', (msg) => {
    const { uri, defs, jumps } = msg;
    definitionsCache.set(uri, { defs: defs || [], jumps: jumps || [] });
  });

  // ── Completion response ──
  onMessage('intel:completion-response', (msg) => {
    const { id } = msg;
    if (id) resolveRequest(id, msg);
  });

  // ── Clear ──
  onMessage('intel:clear', (msg) => {
    const { uri } = msg;
    diagnosticsCache.delete(uri);
    hoversCache.delete(uri);
    arrowsCache.delete(uri);
    colorsCache.delete(uri);
    definitionsCache.delete(uri);
    const model = editor.getModel();
    if (model) monaco.editor.setModelMarkers(model, 'racket', []);
    if (arrowUpdateCallback) arrowUpdateCallback(uri, []);
  });

  // Register Monaco providers
  registerProviders(monaco);

  console.log('[lang-intel] Language intelligence initialised');
}

// ── Diagnostics → Monaco markers ──

function applyDiagnostics(uri, items) {
  if (!monacoRef || !editorRef) return;
  const model = editorRef.getModel();
  if (!model) return;

  const severityMap = {
    error: monacoRef.MarkerSeverity.Error,
    warning: monacoRef.MarkerSeverity.Warning,
    info: monacoRef.MarkerSeverity.Info,
    hint: monacoRef.MarkerSeverity.Hint,
  };

  const markers = items.map((d) => ({
    severity: severityMap[d.severity] || monacoRef.MarkerSeverity.Error,
    message: d.message,
    startLineNumber: d.range.startLine,
    startColumn: d.range.startCol + 1, // Monaco is 1-based columns
    endLineNumber: d.range.endLine,
    endColumn: d.range.endCol + 1,
    source: d.source || 'check-syntax',
  }));

  monacoRef.editor.setModelMarkers(model, 'racket', markers);
}

// ── Semantic colors → decorations ──

let colorDecorations = null;

function applySemanticColors(colors) {
  if (!editorRef) return;

  const decos = colors.map((c) => ({
    range: new monacoRef.Range(
      c.range.startLine, c.range.startCol + 1,
      c.range.endLine, c.range.endCol + 1
    ),
    options: {
      inlineClassName: `hm-cs-${c.style}`,
    },
  }));

  if (colorDecorations) {
    colorDecorations.set(decos);
  } else {
    colorDecorations = editorRef.createDecorationsCollection(decos);
  }
}

// ── Monaco providers ──

function registerProviders(monaco) {
  // Hover provider
  disposables.push(
    monaco.languages.registerHoverProvider('racket', {
      provideHover(model, position) {
        const uri = editorRef?.filePath || '';
        const hovers = hoversCache.get(uri) || [];
        for (const h of hovers) {
          const r = h.range;
          if (position.lineNumber >= r.startLine &&
              position.lineNumber <= r.endLine &&
              position.column >= r.startCol + 1 &&
              position.column <= r.endCol + 1) {
            return {
              range: new monaco.Range(
                r.startLine, r.startCol + 1,
                r.endLine, r.endCol + 1
              ),
              contents: [{ value: h.contents }],
            };
          }
        }
        return null;
      },
    })
  );

  // Definition provider
  disposables.push(
    monaco.languages.registerDefinitionProvider('racket', {
      provideDefinition(model, position) {
        const uri = editorRef?.filePath || '';
        const data = definitionsCache.get(uri);
        if (!data) return null;

        // Check jump targets (references → definition sites)
        for (const j of data.jumps) {
          const r = j.range;
          if (position.lineNumber >= r.startLine &&
              position.lineNumber <= r.endLine &&
              position.column >= r.startCol + 1 &&
              position.column <= r.endCol + 1) {
            // Cross-file jump
            if (j.targetUri) {
              // TODO: open the target file
              return null;
            }
          }
        }

        // Check arrows — find arrow where cursor is at the "to" end
        // and jump to the "from" end (binding site)
        const arrows = arrowsCache.get(uri) || [];
        for (const a of arrows) {
          if (a.kind !== 'binding' && a.kind !== 'require') continue;
          const r = a.to;
          if (position.lineNumber >= r.startLine &&
              position.lineNumber <= r.endLine &&
              position.column >= r.startCol + 1 &&
              position.column <= r.endCol + 1) {
            return {
              uri: model.uri,
              range: new monaco.Range(
                a.from.startLine, a.from.startCol + 1,
                a.from.endLine, a.from.endCol + 1
              ),
            };
          }
        }
        return null;
      },
    })
  );

  // Completion provider (request/response with Racket)
  disposables.push(
    monaco.languages.registerCompletionItemProvider('racket', {
      triggerCharacters: ['('],
      async provideCompletionItems(model, position) {
        const word = model.getWordUntilPosition(position);
        const range = {
          startLineNumber: position.lineNumber,
          endLineNumber: position.lineNumber,
          startColumn: word.startColumn,
          endColumn: word.endColumn,
        };
        const uri = editorRef?.filePath || '';

        try {
          const response = await request('intel:completion-request', {
            uri,
            position: { line: position.lineNumber, col: position.column - 1 },
            prefix: word.word,
          });

          const items = (response?.items || []).map((item) => ({
            label: item.label,
            kind: monaco.languages.CompletionItemKind.Variable,
            insertText: item.label,
            range,
          }));

          return { suggestions: items };
        } catch (err) {
          console.error('[lang-intel] Completion request failed:', err);
          return { suggestions: [] };
        }
      },
    })
  );
}
```

**Step 2: Import lang-intel.js in main.js**

In `frontend/core/main.js`, add the import:

```javascript
import './lang-intel.js';
```

Note: The actual `initLangIntel()` call happens from `editor.js` once Monaco is ready (see Step 3).

**Step 3: Call initLangIntel from editor.js**

In `editor.js`, import `initLangIntel`:

```javascript
import { initLangIntel } from '../lang-intel.js';
```

At the end of `_initMonaco()`, after the editor is created and Cmd+S is bound (after line 173), add:

```javascript
// Initialize language intelligence with Monaco and editor references
initLangIntel(monaco, this._editor);

// Expose filePath on editor for lang-intel to read
this._editor.filePath = this.filePath;
```

Also, in the `editor:open` handler, update the filePath on the editor instance:

```javascript
// After: if (path !== undefined) this.filePath = path;
if (this._editor) this._editor.filePath = this.filePath;
```

**Step 4: Add CSS for semantic coloring**

In `editor.js`, add to the static styles:

```css
/* Check-syntax semantic colors */
.hm-cs-lexically-bound { color: #0000CD !important; } /* blue */
.hm-cs-imported { color: #006400 !important; }         /* dark green */
.hm-cs-set\\!d { color: #8B0000 !important; }          /* dark red */
.hm-cs-free-variable { text-decoration: wavy underline red !important; }
.hm-cs-unused-require { opacity: 0.5 !important; text-decoration: line-through !important; }
```

However, since Monaco uses Shadow DOM internally, we need to inject these styles into the page, not into the component's shadow root. Add a global style injection in the `_initMonaco` method:

```javascript
// Inject check-syntax styles globally (Monaco renders outside shadow roots)
if (!document.getElementById('hm-cs-styles')) {
  const style = document.createElement('style');
  style.id = 'hm-cs-styles';
  style.textContent = `
    .hm-cs-lexically-bound { color: #0000CD !important; }
    .hm-cs-imported { color: #006400 !important; }
    .hm-cs-set\\!d { color: #8B0000 !important; }
    .hm-cs-free-variable { text-decoration: wavy underline red !important; }
    .hm-cs-unused-require { opacity: 0.5 !important; text-decoration: line-through !important; }
  `;
  document.head.appendChild(style);
}
```

Wait — Monaco renders inside the shadow root of `hm-editor`. So inject the style into the shadow root instead:

```javascript
const csStyle = document.createElement('style');
csStyle.textContent = `
  .hm-cs-lexically-bound { color: #0000CD !important; }
  .hm-cs-imported { color: #006400 !important; }
  .hm-cs-set\\!d { color: #8B0000 !important; }
  .hm-cs-free-variable { text-decoration: wavy underline red !important; }
  .hm-cs-unused-require { opacity: 0.5 !important; text-decoration: line-through !important; }
`;
this.shadowRoot.appendChild(csStyle);
```

Add this after `this._editor = monaco.editor.create(...)`.

**Step 5: Verify manually**

Build and run. Open a Racket file with a syntax error. You should see red squiggly underlines in the editor. Open a valid file — you should see semantic coloring (blue for local bindings, green for imports).

**Step 6: Commit**

```bash
git add frontend/core/lang-intel.js frontend/core/main.js frontend/core/primitives/editor.js
git commit -m "feat: diagnostics pipeline — squiggly underlines and semantic colors"
```

---

## Task 6: SVG Arrow Overlay for Check Syntax

**Files:**
- Create: `frontend/core/arrows.js`
- Modify: `frontend/core/primitives/editor.js`

**Step 1: Create arrows.js**

Create `frontend/core/arrows.js`:

```javascript
// arrows.js — SVG overlay for Check Syntax binding arrows
//
// Draws Bezier curves between binding sites and references
// on a transparent SVG layer over the Monaco editor.

import { onArrowsUpdated, getArrows } from './lang-intel.js';

const ARROW_COLORS = {
  binding: '#4488ff',
  require: '#44aa44',
  tail: '#aa44ff',
};

export class ArrowOverlay {
  constructor(editor, monaco, shadowRoot) {
    this._editor = editor;
    this._monaco = monaco;
    this._arrows = [];
    this._svg = null;
    this._disposables = [];

    this._createSvg(shadowRoot);

    // Re-render on scroll and layout changes
    this._disposables.push(
      editor.onDidScrollChange(() => this._render())
    );
    this._disposables.push(
      editor.onDidLayoutChange(() => {
        this._updateSize();
        this._render();
      })
    );

    // Listen for arrow updates from lang-intel
    onArrowsUpdated((uri, arrows) => {
      this._arrows = arrows;
      this._render();
    });

    this._updateSize();
  }

  _createSvg(shadowRoot) {
    this._svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    this._svg.style.position = 'absolute';
    this._svg.style.top = '0';
    this._svg.style.left = '0';
    this._svg.style.pointerEvents = 'none';
    this._svg.style.zIndex = '10';
    this._svg.style.overflow = 'visible';

    // Arrowhead markers
    const defs = document.createElementNS('http://www.w3.org/2000/svg', 'defs');
    for (const [kind, color] of Object.entries(ARROW_COLORS)) {
      const marker = document.createElementNS('http://www.w3.org/2000/svg', 'marker');
      marker.setAttribute('id', `hm-arrow-${kind}`);
      marker.setAttribute('markerWidth', '8');
      marker.setAttribute('markerHeight', '6');
      marker.setAttribute('refX', '8');
      marker.setAttribute('refY', '3');
      marker.setAttribute('orient', 'auto');
      const polygon = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
      polygon.setAttribute('points', '0 0, 8 3, 0 6');
      polygon.setAttribute('fill', color);
      marker.appendChild(polygon);
      defs.appendChild(marker);
    }
    this._svg.appendChild(defs);

    // Insert SVG into the editor's container within the shadow root
    const editorContainer = shadowRoot.getElementById('editor-container');
    if (editorContainer) {
      editorContainer.style.position = 'relative';
      editorContainer.appendChild(this._svg);
    }
  }

  _updateSize() {
    const layout = this._editor.getLayoutInfo();
    this._svg.setAttribute('width', layout.width);
    this._svg.setAttribute('height', layout.height);
  }

  _render() {
    // Clear existing arrows
    const existing = this._svg.querySelectorAll('.hm-arrow');
    existing.forEach((el) => el.remove());

    const layout = this._editor.getLayoutInfo();

    for (const arrow of this._arrows) {
      const fromRange = arrow.from;
      const toRange = arrow.to;
      const kind = arrow.kind || 'binding';
      const color = ARROW_COLORS[kind] || ARROW_COLORS.binding;

      // Get pixel positions for arrow endpoints
      const fromPos = this._editor.getScrolledVisiblePosition({
        lineNumber: fromRange.startLine,
        column: fromRange.startCol + 1,
      });
      const toPos = this._editor.getScrolledVisiblePosition({
        lineNumber: toRange.startLine,
        column: toRange.startCol + 1,
      });

      // Skip if either endpoint is off-screen
      if (!fromPos || !toPos) continue;

      const x1 = fromPos.left + layout.contentLeft;
      const y1 = fromPos.top + fromPos.height / 2;
      const x2 = toPos.left + layout.contentLeft;
      const y2 = toPos.top + toPos.height / 2;

      // Bezier curve (arches above for same-line, to the side for multi-line)
      const dy = Math.abs(y2 - y1);
      const curveOffset = dy < 5 ? -30 : -Math.min(dy * 0.3, 50);
      const midX = (x1 + x2) / 2;
      const midY = Math.min(y1, y2) + curveOffset;

      const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      path.setAttribute('d', `M ${x1} ${y1} Q ${midX} ${midY} ${x2} ${y2}`);
      path.setAttribute('fill', 'none');
      path.setAttribute('stroke', color);
      path.setAttribute('stroke-width', '1.5');
      path.setAttribute('opacity', '0.6');
      path.setAttribute('marker-end', `url(#hm-arrow-${kind})`);
      path.setAttribute('class', 'hm-arrow');

      if (kind === 'tail') {
        path.setAttribute('stroke-dasharray', '4 2');
      }

      this._svg.appendChild(path);
    }
  }

  dispose() {
    for (const d of this._disposables) d.dispose();
    this._disposables = [];
    if (this._svg && this._svg.parentNode) {
      this._svg.parentNode.removeChild(this._svg);
    }
  }
}
```

**Step 2: Mount arrow overlay from editor.js**

In `editor.js`, import `ArrowOverlay`:

```javascript
import { ArrowOverlay } from '../arrows.js';
```

Add a field in the constructor:
```javascript
this._arrowOverlay = null;
```

At the end of `_initMonaco()`, after `initLangIntel(monaco, this._editor)`, add:

```javascript
// Mount Check Syntax arrow overlay
this._arrowOverlay = new ArrowOverlay(this._editor, monaco, this.shadowRoot);
```

In `disconnectedCallback`, add:
```javascript
if (this._arrowOverlay) {
  this._arrowOverlay.dispose();
  this._arrowOverlay = null;
}
```

**Step 3: Verify manually**

Build and run. Open a Racket file like:
```racket
#lang racket
(define x 42)
x
```

You should see a blue Bezier arrow from the definition of `x` to its use on line 3.

**Step 4: Commit**

```bash
git add frontend/core/arrows.js frontend/core/primitives/editor.js
git commit -m "feat: SVG arrow overlay for Check Syntax binding arrows"
```

---

## Task 7: Error Panel Component

**Files:**
- Create: `frontend/core/primitives/error-panel.js`
- Modify: `frontend/core/main.js`
- Modify: `frontend/core/renderer.js`

**Step 1: Create hm-error-panel**

Create `frontend/core/primitives/error-panel.js`:

```javascript
// primitives/error-panel.js — hm-error-panel
//
// Displays a list of diagnostics (errors, warnings) from check-syntax.
// Click a row to jump to the location in the editor.

import { LitElement, html, css } from 'lit';
import { onMessage, dispatch } from '../bridge.js';

class HmErrorPanel extends LitElement {
  static properties = {
    items: { type: Array, state: true },
    visible: { type: Boolean, reflect: true },
  };

  static styles = css`
    :host {
      display: block;
      width: 100%;
      height: 100%;
      overflow: auto;
      background: var(--bg-panel, #F5F5F5);
      font-family: 'SF Mono', 'Fira Code', Menlo, monospace;
      font-size: 12px;
    }

    :host([hidden]) {
      display: none;
    }

    .header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 4px 8px;
      background: var(--bg-panel-header, #E8E8E8);
      font-weight: 600;
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: #555;
      border-bottom: 1px solid #DDD;
    }

    .row {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 3px 8px;
      cursor: pointer;
      border-bottom: 1px solid #EEE;
    }

    .row:hover {
      background: #E3F2FD;
    }

    .icon {
      flex-shrink: 0;
      width: 14px;
      text-align: center;
    }

    .icon.error { color: #D32F2F; }
    .icon.warning { color: #F57F17; }
    .icon.info { color: #1565C0; }

    .message {
      flex: 1;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      color: #333;
    }

    .location {
      flex-shrink: 0;
      color: #888;
      font-size: 11px;
    }

    .empty {
      padding: 8px;
      color: #999;
      font-style: italic;
    }
  `;

  constructor() {
    super();
    this.items = [];
    this.visible = true;
    this._unsubs = [];
  }

  connectedCallback() {
    super.connectedCallback();
    this._unsubs.push(
      onMessage('intel:diagnostics', (msg) => {
        this.items = msg.items || [];
      })
    );
    this._unsubs.push(
      onMessage('intel:clear', () => {
        this.items = [];
      })
    );
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    for (const unsub of this._unsubs) unsub();
    this._unsubs = [];
  }

  _severityIcon(severity) {
    switch (severity) {
      case 'error': return '\u2297';   // ⊗
      case 'warning': return '\u26A0'; // ⚠
      case 'info': return '\u2139';    // ℹ
      default: return '\u2022';        // •
    }
  }

  _handleClick(item) {
    dispatch('editor:goto', {
      line: item.range.startLine,
      col: item.range.startCol,
    });
  }

  render() {
    const count = this.items.length;
    return html`
      <div class="header">
        <span>Problems ${count > 0 ? `(${count})` : ''}</span>
      </div>
      ${count === 0
        ? html`<div class="empty">No problems detected.</div>`
        : this.items.map((item) => html`
            <div class="row" @click=${() => this._handleClick(item)}>
              <span class="icon ${item.severity}">
                ${this._severityIcon(item.severity)}
              </span>
              <span class="message">${item.message}</span>
              <span class="location">
                ${item.range.startLine}:${item.range.startCol}
              </span>
            </div>
          `)
      }
    `;
  }
}

customElements.define('hm-error-panel', HmErrorPanel);
```

**Step 2: Register in renderer.js**

The renderer creates elements by tag name `hm-<type>`. Since the custom element is defined by importing the file, we just need to import it. No changes to `renderer.js` needed — it already uses `document.createElement(tagName)` which works with any registered custom element.

**Step 3: Import in main.js**

Add to `frontend/core/main.js`:

```javascript
import './primitives/error-panel.js';
```

**Step 4: Add error panel to layout (Racket side)**

In `main.rkt`, modify the layout to include an error panel. Replace the terminal section with a vbox containing a panel-header, terminal, and error-panel. The terminal + error-panel live in a vertical split:

In the layout tree, replace the terminal child of the vertical split with a vbox containing both terminal and error panel:

```racket
;; Replace the terminal entry in the inner split children:
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
                 'children (list))))
```

**Step 5: Verify manually**

Build and run. Open a file with a syntax error. The error panel at the bottom should show the error. Click it — nothing will happen yet (editor:goto not handled), but the panel should render.

**Step 6: Add editor:goto handling**

In `main.rkt`, add to `handle-event`:

```racket
    [(string=? event-name "editor:goto")
     (define line (message-ref msg 'line 1))
     (define col (message-ref msg 'col 0))
     (send-message! (make-message "editor:goto"
                                  'line line
                                  'col col))]
```

In `editor.js`, add a bridge listener in `_setupBridgeListeners`:

```javascript
// editor:goto — jump to a specific position
this._unsubs.push(
  onMessage('editor:goto', (msg) => {
    if (this._editor) {
      const { line, col } = msg;
      const position = { lineNumber: line || 1, column: (col || 0) + 1 };
      this._editor.setPosition(position);
      this._editor.revealPositionInCenter(position);
      this._editor.focus();
    }
  })
);
```

**Step 7: Commit**

```bash
git add frontend/core/primitives/error-panel.js frontend/core/main.js \
  frontend/core/primitives/editor.js racket/heavymental-core/main.rkt
git commit -m "feat: error panel component with click-to-navigate"
```

---

## Task 8: REPL Error-to-Source Linking

**Files:**
- Modify: `frontend/core/primitives/terminal.js`

**Step 1: Add error pattern detection to terminal output**

In `terminal.js`, we need to detect Racket error output patterns in PTY output and render them as clickable links. xterm.js supports link providers.

After `this._terminal.open(container)` and `this._fitAddon.fit()` in `_initTerminal()`, add a link provider:

```javascript
// Racket error link provider — detects "path:line:col:" patterns
this._terminal.registerLinkProvider({
  provideLinks: (bufferLineNumber, callback) => {
    const line = this._terminal.buffer.active.getLine(bufferLineNumber);
    if (!line) { callback(undefined); return; }
    const text = line.translateToString();

    // Match Racket error locations: /path/to/file.rkt:10:5:
    const regex = /(\/[^\s:]+\.(?:rkt|rhm|scrbl)):(\d+):(\d+)/g;
    const links = [];
    let match;
    while ((match = regex.exec(text)) !== null) {
      links.push({
        range: {
          start: { x: match.index + 1, y: bufferLineNumber },
          end: { x: match.index + match[0].length + 1, y: bufferLineNumber },
        },
        text: match[0],
        activate: () => {
          const path = match[1];
          const line = parseInt(match[2], 10);
          const col = parseInt(match[3], 10);
          // Dispatch to Racket to open the file and jump
          window.__TAURI__.core.invoke('send_to_racket', {
            message: {
              type: 'event',
              name: 'editor:goto-file',
              path,
              line,
              col,
            },
          }).catch((err) => {
            console.error('[hm-terminal] goto-file failed:', err);
          });
        },
      });
    }
    callback(links.length > 0 ? links : undefined);
  },
});
```

**Step 2: Handle editor:goto-file in Racket**

In `main.rkt`, add to `handle-event`:

```racket
    [(string=? event-name "editor:goto-file")
     (define path (message-ref msg 'path ""))
     (define line (message-ref msg 'line 1))
     (define col (message-ref msg 'col 0))
     (when (not (string=? path ""))
       ;; Read the file and open it, then jump to position
       (send-message! (make-message "file:read" 'path path))
       ;; Queue a goto after the file is opened
       ;; (handle-file-result will emit editor:open, then we send goto)
       ;; For simplicity, send goto with a small delay
       ;; TODO: proper sequencing
       (send-message! (make-message "editor:goto"
                                    'line line
                                    'col col)))]
```

**Step 3: Verify manually**

Build and run. In the REPL, cause an error:
```racket
> (require "nonexistent.rkt")
```
The error output should include a file path that's clickable (underlined on hover in xterm). Clicking should attempt to open the file.

**Step 4: Commit**

```bash
git add frontend/core/primitives/terminal.js racket/heavymental-core/main.rkt
git commit -m "feat: clickable error locations in REPL terminal"
```

---

## Task 9: #lang Detection and Language Switching

**Files:**
- Modify: `racket/heavymental-core/editor.rkt`

**Step 1: Add #lang detection to editor.rkt**

Add a function to detect the `#lang` from file content:

```racket
(define (detect-lang-from-content content)
  (define m (regexp-match #rx"^#lang ([^ \r\n]+)" content))
  (and m (cadr m)))
```

**Step 2: Use #lang for language detection**

In `handle-file-result`, in the `"file:read:result"` case, after reading the content, check the `#lang` line:

```racket
    ["file:read:result"
     (define path (message-ref msg 'path ""))
     (define content (message-ref msg 'content ""))
     ;; Detect language: prefer #lang line, fall back to extension
     (define lang-from-content (detect-lang-from-content content))
     (define lang
       (cond
         [(and lang-from-content (string=? lang-from-content "rhombus")) "rhombus"]
         [(and lang-from-content (string-prefix? lang-from-content "typed/")) "racket"]
         [lang-from-content "racket"]  ;; any #lang → racket for now
         [else (detect-language path)]))
     ;; ... rest unchanged, using lang instead of (detect-language path)
```

Also update `detect-language` for `.rhm` files:

```racket
[(regexp-match? #rx"\\.rhm$" path) "rhombus"]
```

**Step 3: Verify manually**

Open a `.rhm` file — status bar should show "Rhombus" (once we have the tokenizer in Task 10).

**Step 4: Commit**

```bash
git add racket/heavymental-core/editor.rkt
git commit -m "feat: #lang detection for language switching"
```

---

## Task 10: Rhombus Monarch Tokenizer

**Files:**
- Create: `frontend/core/rhombus-language.js`
- Modify: `frontend/core/primitives/editor.js`

**Step 1: Create rhombus-language.js**

Create `frontend/core/rhombus-language.js`:

```javascript
// rhombus-language.js — Monarch tokenizer for Rhombus
//
// Rhombus is a Racket language with Python-like syntax.
// This tokenizer handles the basic syntax for editing comfort.

export const rhombusLanguageId = 'rhombus';

export const rhombusLanguageConfig = {
  comments: {
    lineComment: '//',
    blockComment: ['/*', '*/'],
  },
  brackets: [
    ['(', ')'],
    ['[', ']'],
    ['{', '}'],
  ],
  autoClosingPairs: [
    { open: '(', close: ')' },
    { open: '[', close: ']' },
    { open: '{', close: '}' },
    { open: '"', close: '"', notIn: ['string'] },
    { open: "'", close: "'", notIn: ['string'] },
    { open: '/*', close: '*/' },
  ],
  surroundingPairs: [
    { open: '(', close: ')' },
    { open: '[', close: ']' },
    { open: '{', close: '}' },
    { open: '"', close: '"' },
  ],
  indentationRules: {
    increaseIndentPattern: /:\s*$/,
    decreaseIndentPattern: /^\s*(else|catch|finally)\b/,
  },
};

export const rhombusTokenProvider = {
  defaultToken: '',
  ignoreCase: false,

  keywords: [
    'fun', 'def', 'let', 'val', 'var',
    'class', 'interface', 'extends', 'implements', 'mixin',
    'method', 'override', 'abstract', 'final', 'private',
    'constructor', 'field', 'property',
    'match', 'if', 'cond', 'when', 'unless', 'else',
    'for', 'each', 'in', 'block', 'begin',
    'import', 'export', 'open', 'module', 'namespace',
    'annot', 'bind', 'macro', 'expr', 'defn', 'decl',
    'syntax_class', 'pattern',
    'try', 'catch', 'finally', 'throw',
    'is_a', 'instanceof',
    'this', 'super',
    'enum', 'operator',
    'values', 'return',
  ],

  typeKeywords: [
    'Int', 'String', 'Boolean', 'Float', 'Void', 'Any',
    'List', 'Map', 'Set', 'Array', 'Pair',
    'Syntax', 'Identifier',
  ],

  operators: [
    '=', '==', '!=', '<', '>', '<=', '>=',
    '+', '-', '*', '/', '%',
    '&&', '||', '!', '~',
    '.', '::', ':~', '|>', '++',
    '..', '...', ':',
  ],

  symbols: /[=><!~?:&|+\-*\/\^%]+/,

  tokenizer: {
    root: [
      // #lang line
      [/^#lang\s+.*$/, 'meta'],

      // Whitespace
      [/\s+/, 'white'],

      // Block comments
      [/\/\*/, 'comment', '@blockComment'],

      // Line comments
      [/\/\/.*$/, 'comment'],

      // @-expression comments
      [/@\/\/.*$/, 'comment'],

      // Strings
      [/"/, 'string', '@string'],

      // Character/byte literals
      [/#'[^']*'/, 'string.char'],

      // Booleans
      [/#true\b/, 'constant.boolean'],
      [/#false\b/, 'constant.boolean'],

      // Numbers
      [/[+-]?[0-9]+\.[0-9]*(?:[eE][+-]?[0-9]+)?/, 'number.float'],
      [/[+-]?\.[0-9]+(?:[eE][+-]?[0-9]+)?/, 'number.float'],
      [/0[xX][0-9a-fA-F]+/, 'number.hex'],
      [/0[bB][01]+/, 'number.binary'],
      [/[+-]?[0-9]+/, 'number'],

      // | alternative separator
      [/\|/, 'keyword.operator'],

      // Brackets
      [/[()[\]{}]/, '@brackets'],

      // Operators
      [/@symbols/, {
        cases: {
          '@operators': 'operator',
          '@default': 'delimiter',
        },
      }],

      // Keywords and identifiers
      [/[a-zA-Z_]\w*/, {
        cases: {
          '@keywords': 'keyword',
          '@typeKeywords': 'type',
          '@default': 'identifier',
        },
      }],

      // ~identifier (binding patterns)
      [/~[a-zA-Z_]\w*/, 'variable.parameter'],
    ],

    blockComment: [
      [/\/\*/, 'comment', '@push'],
      [/\*\//, 'comment', '@pop'],
      [/[^/*]+/, 'comment'],
      [/./, 'comment'],
    ],

    string: [
      [/[^\\"$]+/, 'string'],
      [/\\[abtnvfre\\"']/, 'string.escape'],
      [/\$\{/, 'delimiter.bracket', '@interpolation'],
      [/\$[a-zA-Z_]\w*/, 'variable'],
      [/"/, 'string', '@pop'],
    ],

    interpolation: [
      [/\}/, 'delimiter.bracket', '@pop'],
      { include: 'root' },
    ],
  },
};
```

**Step 2: Register Rhombus language in editor.js**

In `editor.js`, import the Rhombus language:

```javascript
import {
  rhombusLanguageId,
  rhombusLanguageConfig,
  rhombusTokenProvider,
} from '../rhombus-language.js';
```

Add a `registerRhombusLanguage` function:

```javascript
let rhombusRegistered = false;

function registerRhombusLanguage(monaco) {
  if (rhombusRegistered) return;
  monaco.languages.register({ id: rhombusLanguageId });
  monaco.languages.setLanguageConfiguration(rhombusLanguageId, rhombusLanguageConfig);
  monaco.languages.setMonarchTokensProvider(rhombusLanguageId, rhombusTokenProvider);
  rhombusRegistered = true;
  console.log('[hm-editor] Rhombus language registered');
}
```

Call it in `_initMonaco`, after `registerRacketLanguage(monaco)`:

```javascript
registerRhombusLanguage(monaco);
```

**Step 3: Verify manually**

Create a `.rhm` file and open it. Syntax highlighting should work for Rhombus keywords, strings, comments, etc.

**Step 4: Commit**

```bash
git add frontend/core/rhombus-language.js frontend/core/primitives/editor.js
git commit -m "feat: Rhombus Monarch tokenizer for syntax highlighting"
```

---

## Task 11: Integration Testing

**Files:**
- Modify: `test/test-lang-intel.rkt`

**Step 1: Add more comprehensive tests**

Add tests for offset-to-position conversion, the push pipeline, and edge cases:

```racket
;; ── Offset conversion tests ──────────────────────────────

(test-case "offset->position handles first line"
  ;; Use the exported offset->position
  (define pos (offset->position "#lang racket\n" 0))
  (check-equal? (hash-ref pos 'line) 1)
  (check-equal? (hash-ref pos 'col) 0))

(test-case "offset->position handles second line"
  (define text "#lang racket\n(define x 42)\n")
  (define pos (offset->position text 14))  ;; first char of line 2
  (check-equal? (hash-ref pos 'line) 2)
  (check-equal? (hash-ref pos 'col) 1))

;; ── Edge cases ────────────────────────────────────────────

(test-case "analyze-source handles empty string"
  (define result (analyze-source "/tmp/empty.rkt" ""))
  (check-true (hash? result)))

(test-case "analyze-source handles non-Racket content gracefully"
  (define result (analyze-source "/tmp/bad.rkt" "this is not racket"))
  (define diags (hash-ref result 'diagnostics))
  (check-true (> (length diags) 0)))
```

Also export `offset->position` from `lang-intel.rkt` by adding it to the `provide` list:

```racket
(provide analyze-source
         push-intel-to-frontend!
         offset->position
         handle-document-opened
         handle-document-changed
         handle-document-closed
         handle-completion-request)
```

**Step 2: Run all tests**

Run:
```bash
racket test/test-lang-intel.rkt
racket test/test-bridge.rkt
racket test/test-phase2.rkt
```

Expected: All tests pass.

**Step 3: Commit**

```bash
git add test/test-lang-intel.rkt racket/heavymental-core/lang-intel.rkt
git commit -m "test: comprehensive lang-intel tests including edge cases"
```

---

## Task 12: Background Analysis with Places (Optimization)

**Files:**
- Modify: `racket/heavymental-core/lang-intel.rkt`

This task makes check-syntax analysis non-blocking by running it on a Racket place.

**Step 1: Add place-based analysis**

Note: This is an optimization. If check-syntax is fast enough for typical files (~100-500ms), this can be deferred. For the initial implementation, `analyze-source` runs synchronously in the event handler. The 500ms debounce on the frontend prevents repeated calls.

If blocking becomes a problem, wrap `analyze-source` in a place:

```racket
(require racket/place)

(define analysis-place #f)

(define (start-analysis-place!)
  (set! analysis-place
    (place ch
      (let loop ()
        (define req (place-channel-get ch))
        (define uri (hash-ref req 'uri))
        (define text (hash-ref req 'text))
        (define result (analyze-source uri text))
        (place-channel-put ch (hasheq 'uri uri 'text text 'result result))
        (loop)))))
```

**For now: skip this task.** Mark as deferred. The synchronous approach works for files under ~1000 lines. We can add places when profiling shows it's needed.

**Step 2: Commit (if implemented)**

```bash
git commit -m "perf: background analysis via places (deferred)"
```

---

## Task 13: Final Verification and Polish

**Step 1: Run all tests**

```bash
racket test/test-bridge.rkt
racket test/test-phase2.rkt
racket test/test-lang-intel.rkt
```

Expected: All pass.

**Step 2: Manual end-to-end verification**

Build and run HeavyMental:
```bash
cargo tauri dev
```

Test checklist:
- [ ] Open a `.rkt` file → semantic coloring appears (blue locals, green imports)
- [ ] Hover over an identifier → tooltip shows type/binding info
- [ ] Ctrl+Click on a reference → jumps to definition
- [ ] Check Syntax arrows visible between bindings and uses
- [ ] Syntax error → red squiggly underline in editor
- [ ] Error panel shows diagnostics with counts
- [ ] Click error in panel → editor jumps to location
- [ ] Edit file → diagnostics update after 500ms pause
- [ ] Run code with error → error location clickable in terminal
- [ ] Open `.rhm` file → Rhombus syntax highlighting works
- [ ] Status bar shows correct language for Rhombus files

**Step 3: Commit any final fixes**

```bash
git add -A
git commit -m "fix: phase 3 polish and integration fixes"
```

---

## Summary

| Task | Description | New Files | Modified Files |
|------|-------------|-----------|----------------|
| 1 | Add drracket-tool-lib dependency | — | info.rkt |
| 2 | Document sync (opened/changed/closed) | — | editor.js, bridge.js |
| 3 | lang-intel.rkt — check-syntax core | lang-intel.rkt, test-lang-intel.rkt | — |
| 4 | Wire lang-intel into main.rkt | — | main.rkt |
| 5 | Diagnostics + semantic colors frontend | lang-intel.js | main.js, editor.js |
| 6 | SVG arrow overlay | arrows.js | editor.js |
| 7 | Error panel component | error-panel.js | main.js, main.rkt, editor.js |
| 8 | REPL error linking | — | terminal.js, main.rkt |
| 9 | #lang detection | — | editor.rkt |
| 10 | Rhombus tokenizer | rhombus-language.js | editor.js |
| 11 | Integration tests | — | test-lang-intel.rkt |
| 12 | Background places (deferred) | — | lang-intel.rkt |
| 13 | Final verification | — | various |
