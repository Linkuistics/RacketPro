# Phase 5a: Extension API Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an extension API that lets Racket modules contribute cells, panels, events, menus, and lifecycle hooks to the running IDE, with live reload support.

**Architecture:** Extensions are `.rkt` files that `provide` a descriptor struct built with `define-extension`. A loader dynamically requires them, registers everything (cells, panels, events, menus) atomically with auto-namespacing, and supports unloading/reloading. The frontend renderer is upgraded to diff layout trees by stable IDs instead of replacing the DOM.

**Tech Stack:** Racket (macros, dynamic-require, namespaces), Lit Web Components, @preact/signals-core, Rust/Tauri (fs watcher via `notify` crate)

---

## Task 1: Extension Descriptor Struct & Macro

**Files:**
- Create: `racket/heavymental-core/extension.rkt`
- Test: `test/test-extension.rkt`

### Step 1: Write failing tests for the extension descriptor

Create `test/test-extension.rkt`:

```racket
#lang racket/base

(require rackunit
         json
         racket/port
         racket/string
         racket/list
         "../racket/heavymental-core/protocol.rkt"
         "../racket/heavymental-core/cell.rkt"
         "../racket/heavymental-core/extension.rkt")

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

;; ── Test: define-extension creates a valid descriptor ────────────────────────

(test-case "define-extension creates extension-descriptor struct"
  (define-extension test-ext
    #:name "Test Extension"
    #:cells ([counter 0] [label "hello"])
    #:events ([#:name "increment"
               #:handler (lambda (msg) (void))]))
  (check-true (extension-descriptor? test-ext))
  (check-equal? (extension-descriptor-id test-ext) 'test-ext)
  (check-equal? (extension-descriptor-name test-ext) "Test Extension"))

(test-case "define-extension captures cells with names and initial values"
  (define-extension cell-test
    #:name "Cell Test"
    #:cells ([count 0] [name "world"]))
  (define cells (extension-descriptor-cells cell-test))
  (check-equal? (length cells) 2)
  ;; Each cell is (cons 'name initial-value)
  (check-equal? (car (first cells)) 'count)
  (check-equal? (cdr (first cells)) 0)
  (check-equal? (car (second cells)) 'name)
  (check-equal? (cdr (second cells)) "world"))

(test-case "define-extension captures events with names and handlers"
  (define handler-called #f)
  (define-extension event-test
    #:name "Event Test"
    #:events ([#:name "do-thing"
               #:handler (lambda (msg) (set! handler-called #t))]))
  (define events (extension-descriptor-events event-test))
  (check-equal? (length events) 1)
  (check-equal? (hash-ref (first events) 'name) "do-thing")
  ;; Call the handler to verify it works
  ((hash-ref (first events) 'handler) (hasheq))
  (check-true handler-called))

(test-case "define-extension captures panels"
  (define-extension panel-test
    #:name "Panel Test"
    #:panels ([#:id "my-panel" #:label "My Panel" #:tab 'bottom
               #:layout (hasheq 'type "vbox"
                                'props (hasheq)
                                'children (list))]))
  (define panels (extension-descriptor-panels panel-test))
  (check-equal? (length panels) 1)
  (check-equal? (hash-ref (first panels) 'id) "my-panel")
  (check-equal? (hash-ref (first panels) 'label) "My Panel")
  (check-equal? (hash-ref (first panels) 'tab) 'bottom))

(test-case "define-extension captures menus"
  (define-extension menu-test
    #:name "Menu Test"
    #:menus ([#:menu "Tools" #:label "My Tool" #:shortcut "Cmd+Shift+T"
              #:action "run-tool"]))
  (define menus (extension-descriptor-menus menu-test))
  (check-equal? (length menus) 1)
  (check-equal? (hash-ref (first menus) 'menu) "Tools")
  (check-equal? (hash-ref (first menus) 'label) "My Tool")
  (check-equal? (hash-ref (first menus) 'action) "run-tool"))

(test-case "define-extension captures lifecycle hooks"
  (define activated #f)
  (define deactivated #f)
  (define-extension lifecycle-test
    #:name "Lifecycle Test"
    #:on-activate (lambda () (set! activated #t))
    #:on-deactivate (lambda () (set! deactivated #t)))
  ;; Hooks are stored as thunks
  (check-true (procedure? (extension-descriptor-on-activate lifecycle-test)))
  ((extension-descriptor-on-activate lifecycle-test))
  (check-true activated)
  ((extension-descriptor-on-deactivate lifecycle-test))
  (check-true deactivated))

(test-case "define-extension with only required fields"
  (define-extension minimal-ext
    #:name "Minimal")
  (check-true (extension-descriptor? minimal-ext))
  (check-equal? (extension-descriptor-cells minimal-ext) '())
  (check-equal? (extension-descriptor-panels minimal-ext) '())
  (check-equal? (extension-descriptor-events minimal-ext) '())
  (check-equal? (extension-descriptor-menus minimal-ext) '())
  (check-false (extension-descriptor-on-activate minimal-ext))
  (check-false (extension-descriptor-on-deactivate minimal-ext)))
```

### Step 2: Run test to verify it fails

Run: `racket test/test-extension.rkt`
Expected: FAIL — cannot find `"../racket/heavymental-core/extension.rkt"`

### Step 3: Implement extension.rkt with struct and macro

Create `racket/heavymental-core/extension.rkt`:

```racket
#lang racket/base

(require racket/list
         racket/string
         "protocol.rkt"
         "cell.rkt")

(provide define-extension
         extension-descriptor
         extension-descriptor?
         extension-descriptor-id
         extension-descriptor-name
         extension-descriptor-cells
         extension-descriptor-panels
         extension-descriptor-events
         extension-descriptor-menus
         extension-descriptor-on-activate
         extension-descriptor-on-deactivate)

;; ── Descriptor struct ────────────────────────────────────────────────────────

(struct extension-descriptor
  (id name cells panels events menus on-activate on-deactivate)
  #:transparent)

;; ── define-extension macro ───────────────────────────────────────────────────
;;
;; Usage:
;;   (define-extension ext-id
;;     #:name "Human Name"
;;     #:cells ([cell-name initial-value] ...)
;;     #:panels ([#:id "id" #:label "Label" #:tab 'bottom #:layout expr] ...)
;;     #:events ([#:name "name" #:handler proc] ...)
;;     #:menus ([#:menu "Menu" #:label "Label" #:shortcut "Cmd+X" #:action "act"] ...)
;;     #:on-activate thunk
;;     #:on-deactivate thunk)
;;
;; All clauses except #:name are optional.

(define-syntax define-extension
  (syntax-rules (#:name #:cells #:panels #:events #:menus #:on-activate #:on-deactivate)
    ;; Entry point: collect keyword arguments into an alist, then expand
    [(_ ext-id clause ...)
     (define ext-id
       (build-extension-descriptor 'ext-id clause ...))]))

;; Helper macro to parse keyword arguments
(define-syntax build-extension-descriptor
  (syntax-rules (#:name #:cells #:panels #:events #:menus #:on-activate #:on-deactivate)
    ;; Base case: all clauses consumed, build the struct
    [(_ id
        (~name name-expr)
        (~cells cells-expr)
        (~panels panels-expr)
        (~events events-expr)
        (~menus menus-expr)
        (~on-activate activate-expr)
        (~on-deactivate deactivate-expr))
     (extension-descriptor id name-expr cells-expr panels-expr
                           events-expr menus-expr
                           activate-expr deactivate-expr)]
    ;; Parse #:name
    [(_ id #:name name-val rest ...)
     (build-extension-descriptor/accum
      id name-val () () () () #f #f rest ...)]
    ;; Error: #:name must come first
    [(_ id other ...)
     (error 'define-extension "#:name must be the first keyword argument")]))

;; Accumulator macro that processes remaining keyword arguments
(define-syntax build-extension-descriptor/accum
  (syntax-rules (#:cells #:panels #:events #:menus #:on-activate #:on-deactivate)
    ;; Done — no more clauses
    [(_ id name cells panels events menus activate deactivate)
     (extension-descriptor id name
                           (reverse cells)
                           (reverse panels)
                           (reverse events)
                           (reverse menus)
                           activate deactivate)]
    ;; #:cells ([name val] ...)
    [(_ id name cells panels events menus activate deactivate
        #:cells ([cell-name cell-val] ...) rest ...)
     (build-extension-descriptor/accum
      id name
      (list (cons 'cell-name cell-val) ...)
      panels events menus activate deactivate rest ...)]
    ;; #:panels ([#:id pid #:label plabel #:tab ptab #:layout playout] ...)
    [(_ id name cells panels events menus activate deactivate
        #:panels ([#:id pid #:label plabel #:tab ptab #:layout playout] ...) rest ...)
     (build-extension-descriptor/accum
      id name cells
      (list (hasheq 'id pid 'label plabel 'tab ptab 'layout playout) ...)
      events menus activate deactivate rest ...)]
    ;; #:events ([#:name ename #:handler ehandler] ...)
    [(_ id name cells panels events menus activate deactivate
        #:events ([#:name ename #:handler ehandler] ...) rest ...)
     (build-extension-descriptor/accum
      id name cells panels
      (list (hasheq 'name ename 'handler ehandler) ...)
      menus activate deactivate rest ...)]
    ;; #:menus ([#:menu mmenu #:label mlabel #:shortcut mshortcut #:action maction] ...)
    [(_ id name cells panels events menus activate deactivate
        #:menus ([#:menu mmenu #:label mlabel #:shortcut mshortcut #:action maction] ...) rest ...)
     (build-extension-descriptor/accum
      id name cells panels events
      (list (hasheq 'menu mmenu 'label mlabel 'shortcut mshortcut 'action maction) ...)
      activate deactivate rest ...)]
    ;; #:on-activate thunk
    [(_ id name cells panels events menus activate deactivate
        #:on-activate new-activate rest ...)
     (build-extension-descriptor/accum
      id name cells panels events menus new-activate deactivate rest ...)]
    ;; #:on-deactivate thunk
    [(_ id name cells panels events menus activate deactivate
        #:on-deactivate new-deactivate rest ...)
     (build-extension-descriptor/accum
      id name cells panels events menus activate new-deactivate rest ...)]))
```

### Step 4: Run tests to verify they pass

Run: `racket test/test-extension.rkt`
Expected: All 7 tests PASS

### Step 5: Commit

```bash
git add racket/heavymental-core/extension.rkt test/test-extension.rkt
git commit -m "feat: add extension descriptor struct and define-extension macro"
```

---

## Task 2: Extension Loader (load/unload/reload)

**Files:**
- Modify: `racket/heavymental-core/extension.rkt`
- Modify: `racket/heavymental-core/cell.rkt`
- Test: `test/test-extension.rkt` (append)

### Step 1: Add cell-unregister! to cell.rkt

Add to the `provide` list in `racket/heavymental-core/cell.rkt:5`:
```racket
cell-unregister!
```

Add after `cell-update!` (after line 38):
```racket
;; Remove a cell and notify the frontend
(define (cell-unregister! name)
  (hash-remove! cells name)
  (send-message! (make-message "cell:unregister"
                               'name (symbol->string name))))
```

### Step 2: Write failing tests for load/unload

Append to `test/test-extension.rkt`:

```racket
;; ── Test: Extension loading registers namespaced cells ───────────────────────

(test-case "load-extension! registers namespaced cells"
  (define-extension loader-test
    #:name "Loader Test"
    #:cells ([counter 0] [label "hi"]))
  (define output
    (with-output-to-string
      (lambda ()
        (load-extension-descriptor! loader-test))))
  (define msgs (parse-all-messages output))
  ;; Should have cell:register messages with prefixed names
  (define registers (find-all-messages-by-type msgs "cell:register"))
  (check-true (>= (length registers) 2))
  (define names (map (lambda (m) (hash-ref m 'name "")) registers))
  (check-true (member "loader-test:counter" names))
  (check-true (member "loader-test:label" names))
  ;; Verify cell values
  (check-equal? (cell-ref 'loader-test:counter) 0)
  (check-equal? (cell-ref 'loader-test:label) "hi")
  ;; Clean up
  (with-output-to-string
    (lambda () (unload-extension! 'loader-test))))

(test-case "load-extension! registers namespaced events"
  (define handler-called #f)
  (define-extension event-loader-test
    #:name "Event Loader"
    #:events ([#:name "click"
               #:handler (lambda (msg) (set! handler-called #t))]))
  (with-output-to-string
    (lambda () (load-extension-descriptor! event-loader-test)))
  ;; Dispatch the namespaced event
  (define handler (get-extension-handler "event-loader-test:click"))
  (check-true (procedure? handler))
  (handler (hasheq))
  (check-true handler-called)
  ;; Clean up
  (with-output-to-string
    (lambda () (unload-extension! 'event-loader-test))))

(test-case "unload-extension! removes cells and events"
  (define-extension unload-test
    #:name "Unload Test"
    #:cells ([val 42])
    #:events ([#:name "act" #:handler (lambda (msg) (void))]))
  (with-output-to-string
    (lambda ()
      (load-extension-descriptor! unload-test)))
  ;; Verify loaded
  (check-equal? (cell-ref 'unload-test:val) 42)
  (check-true (procedure? (get-extension-handler "unload-test:act")))
  ;; Unload
  (define output
    (with-output-to-string
      (lambda () (unload-extension! 'unload-test))))
  ;; Verify cell:unregister sent
  (define msgs (parse-all-messages output))
  (check-true (findf (lambda (m)
                       (and (string=? (hash-ref m 'type "") "cell:unregister")
                            (string=? (hash-ref m 'name "") "unload-test:val")))
                     msgs))
  ;; Verify event handler removed
  (check-false (get-extension-handler "unload-test:act")))

(test-case "on-activate called during load, on-deactivate during unload"
  (define activated #f)
  (define deactivated #f)
  (define-extension lifecycle-loader-test
    #:name "Lifecycle Loader"
    #:on-activate (lambda () (set! activated #t))
    #:on-deactivate (lambda () (set! deactivated #t)))
  (with-output-to-string
    (lambda () (load-extension-descriptor! lifecycle-loader-test)))
  (check-true activated)
  (check-false deactivated)
  (with-output-to-string
    (lambda () (unload-extension! 'lifecycle-loader-test)))
  (check-true deactivated))

(test-case "list-extensions returns loaded extensions"
  (define-extension list-test-a
    #:name "Ext A")
  (define-extension list-test-b
    #:name "Ext B")
  (with-output-to-string
    (lambda ()
      (load-extension-descriptor! list-test-a)
      (load-extension-descriptor! list-test-b)))
  (define exts (list-extensions))
  (check-true (>= (length exts) 2))
  (with-output-to-string
    (lambda ()
      (unload-extension! 'list-test-a)
      (unload-extension! 'list-test-b))))
```

### Step 3: Run tests to verify they fail

Run: `racket test/test-extension.rkt`
Expected: FAIL — `load-extension-descriptor!` not defined

### Step 4: Implement the loader

Add to `extension.rkt` provides:
```racket
load-extension!
load-extension-descriptor!
unload-extension!
reload-extension!
list-extensions
get-extension-handler
get-extension-layout-contributions
```

Add loader implementation after the macro definitions in `extension.rkt`:

```racket
;; ── Extension registry ───────────────────────────────────────────────────────

;; Loaded extensions: symbol id → extension-descriptor
(define loaded-extensions (make-hasheq))

;; Extension event dispatch table: string "ext-id:event-name" → handler proc
(define extension-handlers (make-hash))

;; ── Namespacing helpers ──────────────────────────────────────────────────────

;; Prefix a cell name symbol: 'counter → 'my-ext:counter
(define (prefix-cell-name ext-id cell-name)
  (string->symbol (format "~a:~a" ext-id cell-name)))

;; Prefix an event name string: "click" → "my-ext:click"
(define (prefix-event-name ext-id event-name)
  (format "~a:~a" ext-id event-name))

;; Rewrite cell references in a layout tree:
;; "cell:counter" → "cell:my-ext:counter"
(define (rewrite-cell-refs ext-id layout)
  (cond
    [(hash? layout)
     (define new-props
       (if (hash-has-key? layout 'props)
           (for/hasheq ([(k v) (in-hash (hash-ref layout 'props (hasheq)))])
             (values k (rewrite-cell-ref-value ext-id v)))
           (hasheq)))
     (define new-children
       (if (hash-has-key? layout 'children)
           (for/list ([child (in-list (hash-ref layout 'children '()))])
             (rewrite-cell-refs ext-id child))
           '()))
     (hash-set* layout
                'props new-props
                'children new-children)]
    [else layout]))

(define (rewrite-cell-ref-value ext-id value)
  (cond
    [(and (string? value) (string-prefix? value "cell:"))
     (define cell-name (substring value 5))
     ;; Don't rewrite if already namespaced
     (if (string-contains? cell-name ":")
         value
         (format "cell:~a:~a" ext-id cell-name))]
    [else value]))

;; Rewrite on-click event references: "increment" → "my-ext:increment"
(define (rewrite-event-refs ext-id layout)
  (cond
    [(hash? layout)
     (define props (hash-ref layout 'props (hasheq)))
     (define new-props
       (for/hasheq ([(k v) (in-hash props)])
         (values k
                 (if (and (eq? k 'on-click) (string? v)
                          (not (string-contains? v ":")))
                     (prefix-event-name ext-id v)
                     v))))
     (define new-children
       (for/list ([child (in-list (hash-ref layout 'children '()))])
         (rewrite-event-refs ext-id child)))
     (hash-set* layout
                'props new-props
                'children new-children)]
    [else layout]))

;; ── Loading ──────────────────────────────────────────────────────────────────

;; Load from a descriptor object (used in tests and internally)
(define (load-extension-descriptor! desc)
  (define id (extension-descriptor-id desc))
  (define id-str (symbol->string id))

  ;; Register namespaced cells
  (for ([cell-spec (in-list (extension-descriptor-cells desc))])
    (define prefixed (prefix-cell-name id (car cell-spec)))
    (make-cell prefixed (cdr cell-spec))
    (send-message! (make-message "cell:register"
                                 'name (symbol->string prefixed)
                                 'value (cdr cell-spec))))

  ;; Register namespaced event handlers
  (for ([event-spec (in-list (extension-descriptor-events desc))])
    (define prefixed (prefix-event-name id-str (hash-ref event-spec 'name)))
    (hash-set! extension-handlers prefixed (hash-ref event-spec 'handler)))

  ;; Store in registry
  (hash-set! loaded-extensions id desc)

  ;; Call on-activate
  (define activate (extension-descriptor-on-activate desc))
  (when (and activate (procedure? activate))
    (activate)))

;; Load from a file path (dynamic-require)
(define (load-extension! path)
  (define ns (make-base-namespace))
  (define mod-path (if (path? path) path (string->path path)))
  (define desc (dynamic-require mod-path 'extension #:fail-thunk
                                (lambda ()
                                  (error 'load-extension!
                                         "module at ~a does not provide 'extension"
                                         path))))
  (unless (extension-descriptor? desc)
    (error 'load-extension!
           "module at ~a: 'extension is not an extension-descriptor" path))
  (load-extension-descriptor! desc))

;; ── Unloading ────────────────────────────────────────────────────────────────

(define (unload-extension! ext-id)
  (define desc (hash-ref loaded-extensions ext-id #f))
  (unless desc
    (error 'unload-extension! "extension not loaded: ~a" ext-id))

  (define id-str (symbol->string ext-id))

  ;; Call on-deactivate
  (define deactivate (extension-descriptor-on-deactivate desc))
  (when (and deactivate (procedure? deactivate))
    (deactivate))

  ;; Unregister event handlers
  (for ([event-spec (in-list (extension-descriptor-events desc))])
    (define prefixed (prefix-event-name id-str (hash-ref event-spec 'name)))
    (hash-remove! extension-handlers prefixed))

  ;; Unregister cells
  (for ([cell-spec (in-list (extension-descriptor-cells desc))])
    (define prefixed (prefix-cell-name ext-id (car cell-spec)))
    (cell-unregister! prefixed))

  ;; Remove from registry
  (hash-remove! loaded-extensions ext-id))

;; ── Reload ───────────────────────────────────────────────────────────────────

(define (reload-extension! path)
  ;; Find current ext-id from path (if loaded)
  ;; For simplicity, unload all and reload — caller tracks path→id
  (load-extension! path))

;; ── Queries ──────────────────────────────────────────────────────────────────

(define (list-extensions)
  (hash-values loaded-extensions))

(define (get-extension-handler event-name)
  (hash-ref extension-handlers event-name #f))

;; Collect all panel layout contributions from loaded extensions
;; Returns a list of (hasheq 'id ... 'label ... 'tab ... 'layout ...)
;; with cell refs and event refs already rewritten
(define (get-extension-layout-contributions)
  (apply append
         (for/list ([(id desc) (in-hash loaded-extensions)])
           (define id-str (symbol->string id))
           (for/list ([panel (in-list (extension-descriptor-panels desc))])
             (define layout (hash-ref panel 'layout (hasheq)))
             (define rewritten
               (rewrite-event-refs id-str
                 (rewrite-cell-refs id-str layout)))
             (define panel-id (format "~a:~a" id-str (hash-ref panel 'id "")))
             (hasheq 'id panel-id
                     'label (hash-ref panel 'label "Extension")
                     'tab (hash-ref panel 'tab 'bottom)
                     'layout (hash-set* rewritten
                                        'props (hash-set (hash-ref rewritten 'props (hasheq))
                                                         'data-tab-id panel-id)
                                        ))))))
```

### Step 5: Run tests

Run: `racket test/test-extension.rkt`
Expected: All tests PASS (both old and new)

### Step 6: Commit

```bash
git add racket/heavymental-core/extension.rkt racket/heavymental-core/cell.rkt test/test-extension.rkt
git commit -m "feat: add extension loader with load/unload/reload and namespacing"
```

---

## Task 3: Integrate Extension Dispatch into main.rkt

**Files:**
- Modify: `racket/heavymental-core/main.rkt`

### Step 1: Add extension require

Add to `main.rkt` requires (after line 7):
```racket
         "extension.rkt"
```

### Step 2: Add extension event fallback in handle-event

In `main.rkt`, replace the `else` clause of `handle-event` (line 294):

```racket
    [else
     ;; Check extension dispatch table before logging unknown
     (define ext-handler (get-extension-handler event-name))
     (if ext-handler
         (ext-handler msg)
         (eprintf "Unknown event: ~a\n" event-name))]
```

### Step 3: Add extension:load/unload/reload handlers in dispatch

In `main.rkt`, add before the `[(string=? typ "ping")` clause in `dispatch` (before line 391):

```racket
    ;; Extension management
    [(string=? typ "extension:load")
     (define path (message-ref msg 'path ""))
     (when (not (string=? path ""))
       (with-handlers ([exn:fail?
                        (lambda (e)
                          (eprintf "Extension load error: ~a\n" (exn-message e))
                          (cell-set! 'status (format "Extension error: ~a" (exn-message e))))])
         (load-extension! path)
         (rebuild-layout!)
         (cell-set! 'status (format "Loaded extension: ~a" path))))]
    [(string=? typ "extension:unload")
     (define ext-id-str (message-ref msg 'id ""))
     (when (not (string=? ext-id-str ""))
       (with-handlers ([exn:fail?
                        (lambda (e)
                          (eprintf "Extension unload error: ~a\n" (exn-message e)))])
         (unload-extension! (string->symbol ext-id-str))
         (rebuild-layout!)
         (cell-set! 'status (format "Unloaded extension: ~a" ext-id-str))))]
    [(string=? typ "extension:reload")
     (define path (message-ref msg 'path ""))
     (when (not (string=? path ""))
       (with-handlers ([exn:fail?
                        (lambda (e)
                          (eprintf "Extension reload error: ~a\n" (exn-message e)))])
         (reload-extension! path)
         (rebuild-layout!)
         (cell-set! 'status (format "Reloaded extension: ~a" path))))]
```

### Step 3: Add rebuild-layout! helper

Add after the `initial-layout` definition in `main.rkt` (after line 137):

```racket
;; ── Layout rebuild with extension panels ─────────────────────────

;; Rebuild and re-send the layout, merging extension panel contributions
;; into the bottom tabs area.
(define (rebuild-layout!)
  (define ext-panels (get-extension-layout-contributions))
  (define layout (merge-extension-panels initial-layout ext-panels))
  (send-message! (make-message "layout:set" 'layout layout)))
```

### Step 4: Add merge-extension-panels

Add after `rebuild-layout!`:

```racket
;; Merge extension panels into the layout tree.
;; Extension panels with 'tab = 'bottom are added as children of the
;; bottom-tabs tab-content, and their tab definitions are added to the
;; bottom-tabs component.
(define (merge-extension-panels layout ext-panels)
  (define bottom-panels (filter (lambda (p) (eq? (hash-ref p 'tab 'bottom) 'bottom))
                                ext-panels))
  (if (null? bottom-panels)
      layout
      (add-bottom-tab-panels layout bottom-panels)))

;; Walk the layout tree and inject extension panels into bottom-tabs
(define (add-bottom-tab-panels node ext-panels)
  (define node-type (hash-ref node 'type ""))
  (cond
    ;; Found the bottom-tabs: add extension tab definitions
    [(string=? node-type "bottom-tabs")
     (define existing-tabs (hash-ref (hash-ref node 'props (hasheq)) 'tabs '()))
     (define new-tabs
       (append existing-tabs
               (for/list ([p (in-list ext-panels)])
                 (hasheq 'id (hash-ref p 'id "")
                         'label (hash-ref p 'label "Extension")))))
     (hash-set node 'props
               (hash-set (hash-ref node 'props (hasheq)) 'tabs new-tabs))]
    ;; Found the tab-content: add extension panel layouts as children
    [(string=? node-type "tab-content")
     (define existing-children (hash-ref node 'children '()))
     (define new-children
       (append existing-children
               (for/list ([p (in-list ext-panels)])
                 (hash-ref p 'layout (hasheq)))))
     (hash-set node 'children new-children)]
    ;; Otherwise: recurse into children
    [else
     (define children (hash-ref node 'children '()))
     (if (null? children)
         node
         (hash-set node 'children
                   (for/list ([child (in-list children)])
                     (add-bottom-tab-panels child ext-panels))))]))
```

### Step 5: Add menu rebuilding for extensions

Add after `merge-extension-panels`:

```racket
;; Rebuild the menu with extension menu items merged in
(define (rebuild-menu!)
  (define ext-menus
    (apply append
           (for/list ([desc (in-list (list-extensions))])
             (extension-descriptor-menus desc))))
  (define merged-menu
    (if (null? ext-menus)
        app-menu
        (merge-extension-menus app-menu ext-menus)))
  (send-message! (make-message "menu:set" 'menu merged-menu)))

;; Merge extension menu items into the app menu.
;; Each ext-menu has 'menu (target submenu label) and item fields.
(define (merge-extension-menus menu ext-menus)
  (for/list ([submenu (in-list menu)])
    (define submenu-label (hash-ref submenu 'label ""))
    (define matching
      (filter (lambda (em) (string=? (hash-ref em 'menu "") submenu-label))
              ext-menus))
    (if (null? matching)
        submenu
        (hash-set submenu 'children
                  (append (hash-ref submenu 'children '())
                          (list (hasheq 'label "---"))  ;; separator
                          (for/list ([em (in-list matching)])
                            (hasheq 'label (hash-ref em 'label "")
                                    'shortcut (hash-ref em 'shortcut "")
                                    'action (hash-ref em 'action ""))))))))
```

### Step 6: Update rebuild-layout! to also rebuild menus

Update `rebuild-layout!`:

```racket
(define (rebuild-layout!)
  (define ext-panels (get-extension-layout-contributions))
  (define layout (merge-extension-panels initial-layout ext-panels))
  (send-message! (make-message "layout:set" 'layout layout))
  (rebuild-menu!))
```

### Step 7: Commit

```bash
git add racket/heavymental-core/main.rkt
git commit -m "feat: integrate extension dispatch and layout merging into main.rkt"
```

---

## Task 4: Layout ID Assignment

**Files:**
- Modify: `racket/heavymental-core/main.rkt`
- Modify: `racket/heavymental-core/extension.rkt`

### Step 1: Add assign-layout-ids to extension.rkt

Add to extension.rkt provides:
```racket
assign-layout-ids
```

Add implementation:

```racket
;; ── Layout ID assignment ─────────────────────────────────────────────────────

;; Walk a layout tree and assign 'id to any node missing one.
;; IDs are generated from type + sibling index: "vbox-0", "editor-1", etc.
;; Nodes that already have an 'id in their props are left unchanged.
(define (assign-layout-ids tree [prefix ""])
  (cond
    [(hash? tree)
     (define node-type (hash-ref tree 'type "node"))
     (define props (hash-ref tree 'props (hasheq)))
     (define existing-id (hash-ref props 'id #f))
     (define node-id (or existing-id
                         (if (string=? prefix "")
                             node-type
                             (format "~a/~a" prefix node-type))))
     ;; Assign ID if missing
     (define new-props
       (if existing-id props (hash-set props 'id node-id)))
     ;; Recurse into children, using sibling index to disambiguate
     (define children (hash-ref tree 'children '()))
     (define type-counts (make-hash))  ;; track sibling indices by type
     (define new-children
       (for/list ([child (in-list children)])
         (define child-type (if (hash? child) (hash-ref child 'type "node") "node"))
         (define idx (hash-ref type-counts child-type 0))
         (hash-set! type-counts child-type (add1 idx))
         (define child-prefix (format "~a/~a-~a" node-id child-type idx))
         (assign-layout-ids child child-prefix)))
     (hash-set* tree
                'props new-props
                'children new-children)]
    [else tree]))
```

### Step 2: Wire into the startup sequence in main.rkt

In `main.rkt`, change the layout:set send at line 407:

```racket
(send-message! (make-message "layout:set" 'layout (assign-layout-ids initial-layout)))
```

And update `rebuild-layout!`:

```racket
(define (rebuild-layout!)
  (define ext-panels (get-extension-layout-contributions))
  (define layout (merge-extension-panels initial-layout ext-panels))
  (send-message! (make-message "layout:set" 'layout (assign-layout-ids layout)))
  (rebuild-menu!))
```

### Step 3: Add tests for ID assignment

Append to `test/test-extension.rkt`:

```racket
;; ── Test: assign-layout-ids ──────────────────────────────────────────────────

(test-case "assign-layout-ids adds IDs to nodes without them"
  (define tree
    (hasheq 'type "vbox"
            'props (hasheq)
            'children
            (list (hasheq 'type "editor"
                          'props (hasheq)
                          'children (list))
                  (hasheq 'type "terminal"
                          'props (hasheq)
                          'children (list)))))
  (define result (assign-layout-ids tree))
  ;; Root gets its type as ID
  (check-equal? (hash-ref (hash-ref result 'props) 'id) "vbox")
  ;; Children get prefixed IDs with sibling index
  (define children (hash-ref result 'children))
  (check-equal? (hash-ref (hash-ref (first children) 'props) 'id)
                "vbox/editor-0")
  (check-equal? (hash-ref (hash-ref (second children) 'props) 'id)
                "vbox/terminal-0"))

(test-case "assign-layout-ids preserves existing IDs"
  (define tree
    (hasheq 'type "vbox"
            'props (hasheq 'id "my-root")
            'children
            (list (hasheq 'type "editor"
                          'props (hasheq 'id "main-editor")
                          'children (list)))))
  (define result (assign-layout-ids tree))
  (check-equal? (hash-ref (hash-ref result 'props) 'id) "my-root")
  (define children (hash-ref result 'children))
  (check-equal? (hash-ref (hash-ref (first children) 'props) 'id) "main-editor"))

(test-case "assign-layout-ids disambiguates siblings of same type"
  (define tree
    (hasheq 'type "vbox"
            'props (hasheq)
            'children
            (list (hasheq 'type "editor" 'props (hasheq) 'children (list))
                  (hasheq 'type "editor" 'props (hasheq) 'children (list)))))
  (define result (assign-layout-ids tree))
  (define children (hash-ref result 'children))
  (define id0 (hash-ref (hash-ref (first children) 'props) 'id))
  (define id1 (hash-ref (hash-ref (second children) 'props) 'id))
  (check-not-equal? id0 id1))
```

### Step 4: Run tests

Run: `racket test/test-extension.rkt`
Expected: All tests PASS

### Step 5: Commit

```bash
git add racket/heavymental-core/extension.rkt racket/heavymental-core/main.rkt test/test-extension.rkt
git commit -m "feat: add layout ID assignment for stable diffing"
```

---

## Task 5: Frontend Diffing Renderer

**Files:**
- Modify: `frontend/core/renderer.js`
- Modify: `frontend/core/cells.js`

### Step 1: Add cell:unregister handler to cells.js

In `frontend/core/cells.js`, add after the `cell:update` handler (after line 67):

```javascript
  // cell:unregister — Racket sends this when an extension unloads
  onMessage('cell:unregister', (msg) => {
    const { name } = msg;
    if (!name) return;
    cells.delete(name);
    console.debug(`[cells] unregistered "${name}"`);
  });
```

### Step 2: Rewrite renderer.js with ID-based diffing

Replace the full contents of `frontend/core/renderer.js`:

```javascript
// renderer.js — Layout tree to DOM with ID-based diffing
//
// The Racket process sends a layout tree (via "layout:set") describing the
// UI as nested nodes. Each node carries a stable 'id' in its props, assigned
// by Racket. The renderer diffs by ID: matching nodes are reused and updated
// in place, new nodes are created, missing nodes are removed.

import { onMessage } from './bridge.js';

/** @type {HTMLElement|null} */
let root = null;

/**
 * Create a `hm-<type>` custom element from a node descriptor, set its
 * properties, and recursively render its children.
 *
 * @param {object} node — { type, props, children }
 * @param {HTMLElement} parent — DOM element to append into
 * @param {number} index — sibling index (for slot assignment)
 */
function createNode(node, parent, index = 0) {
  if (!node || !node.type) return null;

  const tagName = `hm-${node.type}`;
  const el = document.createElement(tagName);

  // Set all props
  applyProps(el, node.type, node.props || {});

  // Recursively create children
  if (Array.isArray(node.children)) {
    node.children.forEach((child, i) => {
      createNode(child, el, i);
    });
  }

  // Assign named slots for hm-split children
  if (parent && parent.tagName === 'HM-SPLIT') {
    el.slot = index === 0 ? 'first' : 'second';
    el.style.width = '100%';
    el.style.height = '100%';
  }

  parent.appendChild(el);
  return el;
}

/**
 * Apply props from a layout node to a DOM element.
 */
function applyProps(el, nodeType, props) {
  const propMap = {
    text: 'content',
    style: 'textStyle',
  };

  for (const [key, value] of Object.entries(props)) {
    // Skip 'id' — it's for diffing, not a DOM property
    if (key === 'id') continue;

    const mapped = propMap[key];
    if (mapped && (nodeType === 'heading' || nodeType === 'text')) {
      el[mapped] = value;
    } else if (key.includes('-')) {
      el.setAttribute(key, value);
    } else {
      el[key] = value;
    }
  }
}

/**
 * Diff-reconcile a new layout tree against existing DOM children.
 * Matches nodes by their 'id' prop for stable identity.
 *
 * @param {HTMLElement} parent — the DOM parent to reconcile into
 * @param {Array} newChildren — array of layout node descriptors
 * @param {number} depth — recursion depth (for split slot assignment)
 */
function reconcileChildren(parent, newChildren) {
  if (!Array.isArray(newChildren)) newChildren = [];

  // Build map: id → existing DOM element
  const existingById = new Map();
  for (const child of parent.children) {
    const id = child.dataset?.layoutId;
    if (id) {
      existingById.set(id, child);
    }
  }

  // Track which elements we've matched
  const matched = new Set();
  const newOrder = [];

  for (let i = 0; i < newChildren.length; i++) {
    const node = newChildren[i];
    if (!node || !node.type) continue;

    const nodeId = node.props?.id;
    const existing = nodeId ? existingById.get(nodeId) : null;

    if (existing && existing.tagName === `HM-${node.type}`.toUpperCase()) {
      // Reuse existing element — update props
      applyProps(existing, node.type, node.props || {});

      // Assign split slots if needed
      if (parent.tagName === 'HM-SPLIT') {
        existing.slot = i === 0 ? 'first' : 'second';
        existing.style.width = '100%';
        existing.style.height = '100%';
      }

      // Recursively reconcile children
      reconcileChildren(existing, node.children || []);

      matched.add(nodeId);
      newOrder.push(existing);
    } else {
      // New node — create it
      const el = document.createElement(`hm-${node.type}`);
      applyProps(el, node.type, node.props || {});

      // Store layout ID for future diffing
      if (nodeId) {
        el.dataset.layoutId = nodeId;
      }

      // Assign split slots
      if (parent.tagName === 'HM-SPLIT') {
        el.slot = i === 0 ? 'first' : 'second';
        el.style.width = '100%';
        el.style.height = '100%';
      }

      // Recursively create children
      if (Array.isArray(node.children)) {
        node.children.forEach((child, ci) => {
          createNode(child, el, ci);
        });
      }

      newOrder.push(el);
    }
  }

  // Remove unmatched elements (extension panels that were unloaded, etc.)
  for (const [id, el] of existingById) {
    if (!matched.has(id)) {
      el.remove();
    }
  }

  // Reorder DOM children to match new layout order
  for (let i = 0; i < newOrder.length; i++) {
    const el = newOrder[i];
    if (el.parentNode !== parent) {
      parent.appendChild(el);
    } else if (parent.children[i] !== el) {
      parent.insertBefore(el, parent.children[i]);
    }
  }
}

/**
 * Set (or diff-update) the full layout tree.
 *
 * On first call, creates the entire tree from scratch.
 * On subsequent calls, diffs by node ID to preserve existing DOM elements.
 *
 * @param {object} tree — root node of the layout tree
 */
export function setLayout(tree) {
  if (!root) {
    console.error('[renderer] No root container — call initRenderer() first');
    return;
  }

  if (root.children.length === 0) {
    // First render — create everything, set up root styles
    root.textContent = '';
    root.style.display = 'flex';
    root.style.flexDirection = 'column';
    root.style.alignItems = 'stretch';
    root.style.justifyContent = 'stretch';
    root.style.fontSize = '';
    root.style.overflow = 'hidden';

    // Create the root node and mark it with layout ID
    const el = document.createElement(`hm-${tree.type}`);
    applyProps(el, tree.type, tree.props || {});
    if (tree.props?.id) {
      el.dataset.layoutId = tree.props.id;
    }

    if (Array.isArray(tree.children)) {
      tree.children.forEach((child, i) => {
        createNode(child, el, i);
      });
    }

    // Mark all elements with layout IDs for future diffing
    assignLayoutIds(el, tree);

    root.appendChild(el);
    console.debug('[renderer] Layout rendered (initial)');
  } else {
    // Subsequent render — diff against existing DOM
    const rootEl = root.children[0];
    if (!rootEl) {
      // Shouldn't happen, but fallback to full create
      setLayout(tree);
      return;
    }

    // Update root props
    applyProps(rootEl, tree.type, tree.props || {});

    // Reconcile children
    reconcileChildren(rootEl, tree.children || []);

    console.debug('[renderer] Layout reconciled (diff)');
  }
}

/**
 * Walk a newly created DOM tree and stamp layout IDs from the layout tree
 * onto elements as data-layout-id attributes.
 */
function assignLayoutIds(el, node) {
  if (!node || !el) return;
  const nodeId = node.props?.id;
  if (nodeId) {
    el.dataset.layoutId = nodeId;
  }
  const children = node.children || [];
  // el.children may include more than layout children (shadow DOM), so
  // we match by index only for the layout-created children.
  let domIdx = 0;
  for (let i = 0; i < children.length; i++) {
    if (domIdx < el.children.length) {
      assignLayoutIds(el.children[domIdx], children[i]);
      domIdx++;
    }
  }
}

/**
 * Re-exported for compatibility — delegates to createNode.
 */
export function renderNode(node, parent, index = 0) {
  return createNode(node, parent, index);
}

/**
 * Initialise the renderer.
 *
 * @param {HTMLElement} container — the root DOM element (#app)
 */
export function initRenderer(container) {
  root = container;

  onMessage('layout:set', (msg) => {
    const layout = msg.layout;
    if (layout) {
      setLayout(layout);
    } else {
      console.warn('[renderer] layout:set message missing "layout" field', msg);
    }
  });

  console.log('[renderer] Renderer initialised');
}
```

### Step 3: Commit

```bash
git add frontend/core/renderer.js frontend/core/cells.js
git commit -m "feat: ID-based diffing renderer and cell:unregister support"
```

---

## Task 6: Demo Extension 1 — Counter Panel

**Files:**
- Create: `extensions/counter.rkt`

### Step 1: Create the extensions directory and counter extension

```bash
mkdir -p extensions
```

Create `extensions/counter.rkt`:

```racket
#lang racket/base

(require "../racket/heavymental-core/extension.rkt"
         "../racket/heavymental-core/cell.rkt")

(define-extension counter-ext
  #:name "Counter"
  #:cells ([count 0])
  #:panels ([#:id "counter" #:label "Counter" #:tab 'bottom
             #:layout (hasheq 'type "vbox"
                              'props (hasheq 'flex "1")
                              'children
                              (list
                               (hasheq 'type "text"
                                       'props (hasheq 'text "cell:count")
                                       'children (list))
                               (hasheq 'type "button"
                                       'props (hasheq 'label "+1"
                                                      'on-click "increment")
                                       'children (list))))])
  #:events ([#:name "increment"
             #:handler (lambda (msg)
                         (cell-update! 'counter-ext:count add1))]))

(provide (rename-out [counter-ext extension]))
```

### Step 2: Write a test for loading the counter extension

Append to `test/test-extension.rkt`:

```racket
;; ── Test: Counter extension loads and works ──────────────────────────────────

(test-case "counter extension: load, increment, unload"
  (define-extension counter-test
    #:name "Counter"
    #:cells ([count 0])
    #:events ([#:name "increment"
               #:handler (lambda (msg)
                           (cell-update! 'counter-test:count add1))]))
  ;; Load
  (with-output-to-string
    (lambda () (load-extension-descriptor! counter-test)))
  (check-equal? (cell-ref 'counter-test:count) 0)
  ;; Increment via handler
  (define handler (get-extension-handler "counter-test:increment"))
  (check-true (procedure? handler))
  (with-output-to-string
    (lambda () (handler (hasheq))))
  (check-equal? (cell-ref 'counter-test:count) 1)
  ;; Increment again
  (with-output-to-string
    (lambda () (handler (hasheq))))
  (check-equal? (cell-ref 'counter-test:count) 2)
  ;; Unload
  (with-output-to-string
    (lambda () (unload-extension! 'counter-test)))
  (check-false (get-extension-handler "counter-test:increment")))
```

### Step 3: Run tests

Run: `racket test/test-extension.rkt`
Expected: All tests PASS

### Step 4: Commit

```bash
git add extensions/counter.rkt test/test-extension.rkt
git commit -m "feat: add counter demo extension (Demo 1)"
```

---

## Task 7: Demo Extension 2 — Calc Language

**Files:**
- Create: `extensions/calc-lang.rkt`
- Test: `test/test-extension.rkt` (append)

### Step 1: Create the calc language extension

Create `extensions/calc-lang.rkt`:

```racket
#lang racket/base

(require racket/port
         "../racket/heavymental-core/extension.rkt"
         "../racket/heavymental-core/cell.rkt"
         "../racket/heavymental-core/protocol.rkt")

;; Simple arithmetic evaluator for the calc "language"
(define (eval-calc-expr str)
  (with-handlers ([exn:fail? (lambda (e) (format "Error: ~a" (exn-message e)))])
    (define result
      (parameterize ([current-namespace (make-base-namespace)])
        (eval (read (open-input-string str)))))
    (format "~a" result)))

(define-extension calc-lang-ext
  #:name "Calc Language"
  #:cells ([calc-output ""])
  #:panels ([#:id "calc" #:label "Calc" #:tab 'bottom
             #:layout (hasheq 'type "vbox"
                              'props (hasheq 'flex "1")
                              'children
                              (list
                               (hasheq 'type "text"
                                       'props (hasheq 'text "cell:calc-output"
                                                      'style "monospace")
                                       'children (list))))])
  #:menus ([#:menu "Racket" #:label "Eval as Calc" #:shortcut "Cmd+Shift+C"
            #:action "eval-calc"])
  #:events ([#:name "eval-calc"
             #:handler (lambda (msg)
                         ;; msg may contain 'content from a future editor-content request
                         ;; For now, use a placeholder
                         (define content (hash-ref msg 'content "(+ 1 2 3)" #f))
                         (define result (eval-calc-expr (or content "(+ 1 2 3)")))
                         (cell-set! 'calc-lang-ext:calc-output result))]))

(provide (rename-out [calc-lang-ext extension]))
```

### Step 2: Add test

Append to `test/test-extension.rkt`:

```racket
;; ── Test: Calc language extension ────────────────────────────────────────────

(test-case "calc-lang extension: eval arithmetic expressions"
  (define-extension calc-test
    #:name "Calc"
    #:cells ([result ""])
    #:events ([#:name "eval"
               #:handler (lambda (msg)
                           (define expr (hash-ref msg 'content "(+ 1 2 3)"))
                           (define val
                             (with-handlers ([exn:fail? (lambda (e) "error")])
                               (format "~a"
                                 (parameterize ([current-namespace (make-base-namespace)])
                                   (eval (read (open-input-string expr)))))))
                           (cell-set! 'calc-test:result val))]))
  (with-output-to-string
    (lambda () (load-extension-descriptor! calc-test)))
  (define handler (get-extension-handler "calc-test:eval"))
  (with-output-to-string
    (lambda () (handler (hasheq 'content "(* 6 7)"))))
  (check-equal? (cell-ref 'calc-test:result) "42")
  (with-output-to-string
    (lambda () (unload-extension! 'calc-test))))
```

### Step 3: Run tests

Run: `racket test/test-extension.rkt`
Expected: All tests PASS

### Step 4: Commit

```bash
git add extensions/calc-lang.rkt test/test-extension.rkt
git commit -m "feat: add calc language demo extension (Demo 2)"
```

---

## Task 8: FS Watcher Plumbing (Rust)

**Files:**
- Modify: `src-tauri/Cargo.toml`
- Modify: `src-tauri/src/bridge.rs`

### Step 1: Add notify dependency

In `src-tauri/Cargo.toml`, add to `[dependencies]`:

```toml
notify = "7"
```

### Step 2: Add fs:watch/unwatch intercepted messages

In `bridge.rs`, add a new `FsWatcher` struct and integrate it. Add after the existing PTY imports at the top:

```rust
use notify::{self, RecursiveMode, Watcher, EventKind};
use std::collections::HashMap;
```

Add a new struct for FS watching (before `handle_intercepted_message`):

```rust
/// Manages filesystem watchers for extensions.
pub struct FsWatchManager {
    watchers: std::sync::Mutex<HashMap<String, notify::RecommendedWatcher>>,
}

impl FsWatchManager {
    pub fn new() -> Self {
        Self {
            watchers: std::sync::Mutex::new(HashMap::new()),
        }
    }

    pub fn watch(&self, id: &str, path: &str, tx: &mpsc::Sender<Value>) -> Result<(), String> {
        let tx = tx.clone();
        let watch_id = id.to_string();
        let mut watcher = notify::recommended_watcher(move |res: Result<notify::Event, notify::Error>| {
            match res {
                Ok(event) => {
                    let kind = match event.kind {
                        EventKind::Create(_) => "create",
                        EventKind::Modify(_) => "modify",
                        EventKind::Remove(_) => "remove",
                        _ => return,
                    };
                    for path in &event.paths {
                        let msg = json!({
                            "type": "fs:change",
                            "watch-id": watch_id,
                            "event": kind,
                            "path": path.to_string_lossy(),
                        });
                        let _ = tx.send(msg);
                    }
                }
                Err(e) => {
                    eprintln!("[fs-watch] Error: {e}");
                }
            }
        }).map_err(|e| format!("Failed to create watcher: {e}"))?;

        watcher.watch(std::path::Path::new(path), RecursiveMode::Recursive)
            .map_err(|e| format!("Failed to watch path: {e}"))?;

        self.watchers.lock().unwrap().insert(id.to_string(), watcher);
        Ok(())
    }

    pub fn unwatch(&self, id: &str) {
        self.watchers.lock().unwrap().remove(id);
    }

    pub fn unwatch_all(&self) {
        self.watchers.lock().unwrap().clear();
    }
}
```

Add `fs:watch` and `fs:unwatch` to `handle_intercepted_message`. The function signature needs an additional `fs_watcher: &FsWatchManager` parameter. Add these match arms before the `_ => false` fallback:

```rust
        // ----- FS Watcher --------------------------------------------------
        "fs:watch" => {
            let id = msg.get("id").and_then(|v| v.as_str()).unwrap_or("");
            let path = msg.get("path").and_then(|v| v.as_str()).unwrap_or("");
            if let Err(e) = fs_watcher.watch(id, path, tx) {
                log::error!("fs:watch failed: {e}");
            }
            true
        }
        "fs:unwatch" => {
            let id = msg.get("id").and_then(|v| v.as_str()).unwrap_or("");
            fs_watcher.unwatch(id);
            true
        }
        "fs:unwatch-all" => {
            fs_watcher.unwatch_all();
            true
        }
```

Update the `RacketBridge` struct to hold an `FsWatchManager` and pass it through to `process_message` / `handle_intercepted_message`. The `FsWatchManager` is created alongside the `PtyManager` in the bridge startup code.

### Step 3: Build to verify compilation

Run: `cd src-tauri && cargo check`
Expected: Compiles successfully

### Step 4: Commit

```bash
git add src-tauri/Cargo.toml src-tauri/src/bridge.rs
git commit -m "feat: add filesystem watcher support via notify crate"
```

---

## Task 9: Demo Extension 3 — File Watcher

**Files:**
- Create: `extensions/file-watcher.rkt`
- Modify: `racket/heavymental-core/extension.rkt` (add FS watcher API)
- Test: `test/test-extension.rkt` (append)

### Step 1: Add watch-directory! and unwatch-all! to extension.rkt

Add to provides in `extension.rkt`:
```racket
watch-directory!
unwatch-all!
```

Add implementation:

```racket
;; ── Filesystem watcher API ───────────────────────────────────────────────────

;; Active watcher callbacks: watch-id → callback
(define fs-watch-callbacks (make-hash))
(define _next-watch-id 0)

;; Start watching a directory. Callback receives (event-type path-string).
;; Returns a watch-id string.
(define (watch-directory! path callback)
  (set! _next-watch-id (add1 _next-watch-id))
  (define watch-id (format "watch-~a" _next-watch-id))
  (hash-set! fs-watch-callbacks watch-id callback)
  (send-message! (make-message "fs:watch"
                               'id watch-id
                               'path path))
  watch-id)

;; Stop all filesystem watchers
(define (unwatch-all!)
  (send-message! (make-message "fs:unwatch-all"))
  (hash-clear! fs-watch-callbacks))

;; Handle fs:change events from Rust (called by dispatch in main.rkt)
(define (handle-fs-change msg)
  (define watch-id (message-ref msg 'watch-id ""))
  (define event-type (message-ref msg 'event ""))
  (define path (message-ref msg 'path ""))
  (define callback (hash-ref fs-watch-callbacks watch-id #f))
  (when callback
    (callback event-type path)))
```

### Step 2: Wire fs:change into main.rkt dispatch

Add to `main.rkt` dispatch, before the ping handler:

```racket
    [(string=? typ "fs:change")
     (handle-fs-change msg)]
```

And add `handle-fs-change` to the require from `extension.rkt`.

### Step 3: Create the file watcher extension

Create `extensions/file-watcher.rkt`:

```racket
#lang racket/base

(require racket/list
         "../racket/heavymental-core/extension.rkt"
         "../racket/heavymental-core/cell.rkt")

(define-extension file-watcher-ext
  #:name "File Watcher"
  #:cells ([recent-changes (list)])
  #:panels ([#:id "watcher" #:label "Changes" #:tab 'bottom
             #:layout (hasheq 'type "vbox"
                              'props (hasheq 'flex "1")
                              'children
                              (list
                               (hasheq 'type "text"
                                       'props (hasheq 'text "cell:recent-changes")
                                       'children (list))))])
  #:on-activate
  (lambda ()
    (define root (cell-ref 'project-root))
    (when (and (string? root) (not (string=? root "")))
      (watch-directory! root
        (lambda (event path)
          (cell-update! 'file-watcher-ext:recent-changes
            (lambda (lst)
              ;; Keep last 20 changes
              (take (cons (format "~a: ~a" event path) lst)
                    (min 20 (add1 (length lst))))))))))
  #:on-deactivate
  (lambda ()
    (unwatch-all!)))

(provide (rename-out [file-watcher-ext extension]))
```

### Step 4: Add test for FS watcher API (unit level)

Append to `test/test-extension.rkt`:

```racket
;; ── Test: File watcher lifecycle hooks ───────────────────────────────────────

(test-case "file watcher extension: lifecycle hooks fire"
  (define activated #f)
  (define deactivated #f)
  (define-extension watcher-test
    #:name "Watcher Test"
    #:on-activate (lambda () (set! activated #t))
    #:on-deactivate (lambda () (set! deactivated #t)))
  (with-output-to-string
    (lambda () (load-extension-descriptor! watcher-test)))
  (check-true activated)
  (with-output-to-string
    (lambda () (unload-extension! 'watcher-test)))
  (check-true deactivated))
```

### Step 5: Run tests

Run: `racket test/test-extension.rkt`
Expected: All tests PASS

### Step 6: Commit

```bash
git add extensions/file-watcher.rkt racket/heavymental-core/extension.rkt racket/heavymental-core/main.rkt test/test-extension.rkt
git commit -m "feat: add file watcher demo extension with FS API (Demo 3)"
```

---

## Task 10: Integration Test & Manual Verification

**Files:**
- Modify: `test/test-extension.rkt` (final integration test)

### Step 1: Add end-to-end extension lifecycle test

Append to `test/test-extension.rkt`:

```racket
;; ── Integration: full extension lifecycle ────────────────────────────────────

(test-case "integration: load → use → reload → unload lifecycle"
  ;; Load
  (define-extension integration-ext
    #:name "Integration"
    #:cells ([val 0])
    #:events ([#:name "bump"
               #:handler (lambda (msg)
                           (cell-update! 'integration-ext:val add1))]))
  (with-output-to-string
    (lambda () (load-extension-descriptor! integration-ext)))

  ;; Use
  (define handler (get-extension-handler "integration-ext:bump"))
  (with-output-to-string (lambda () (handler (hasheq))))
  (check-equal? (cell-ref 'integration-ext:val) 1)

  ;; Verify it's listed
  (check-true (> (length (list-extensions)) 0))

  ;; Unload
  (with-output-to-string
    (lambda () (unload-extension! 'integration-ext)))
  (check-false (get-extension-handler "integration-ext:bump"))

  ;; Re-load (simulating reload)
  (with-output-to-string
    (lambda () (load-extension-descriptor! integration-ext)))
  (check-equal? (cell-ref 'integration-ext:val) 0)  ;; reset to initial
  (with-output-to-string
    (lambda () (unload-extension! 'integration-ext))))

(test-case "integration: extension layout contributions have correct IDs"
  (define-extension layout-int-test
    #:name "Layout Integration"
    #:panels ([#:id "my-panel" #:label "Test Panel" #:tab 'bottom
               #:layout (hasheq 'type "vbox"
                                'props (hasheq)
                                'children (list))]))
  (with-output-to-string
    (lambda () (load-extension-descriptor! layout-int-test)))
  (define contributions (get-extension-layout-contributions))
  (check-true (> (length contributions) 0))
  (define panel (first contributions))
  (check-equal? (hash-ref panel 'id) "layout-int-test:my-panel")
  (check-equal? (hash-ref panel 'label) "Test Panel")
  (with-output-to-string
    (lambda () (unload-extension! 'layout-int-test))))
```

### Step 2: Run ALL tests

Run: `racket test/test-extension.rkt && racket test/test-bridge.rkt && racket test/test-phase2.rkt && racket test/test-phase4.rkt && racket test/test-lang-intel.rkt && racket test/test-stepper.rkt && racket test/test-macro-expander.rkt && racket test/test-pattern-extractor.rkt && racket test/test-rhombus.rkt`
Expected: All tests PASS — no regressions

### Step 3: Manual test with `cargo tauri dev`

Run: `cargo tauri dev`

Verify:
1. App starts normally, layout renders, no console errors
2. REPL works, file open/save works, stepper works (no regressions)
3. Layout IDs are assigned (check DOM for `data-layout-id` attributes)

### Step 4: Commit

```bash
git add test/test-extension.rkt
git commit -m "test: add integration tests for extension lifecycle"
```

---

## Task 11: Update Next Session Prompt & Memory

**Files:**
- Modify: `docs/plans/next-session-prompt.md`
- Memory update

### Step 1: Update next-session-prompt.md

Replace the file content to reflect Phase 5a completion and Phase 5b planning.

### Step 2: Update MEMORY.md

Add Phase 5a completion notes.

### Step 3: Commit

```bash
git add docs/plans/next-session-prompt.md
git commit -m "docs: update next session prompt for Phase 5b planning"
```
