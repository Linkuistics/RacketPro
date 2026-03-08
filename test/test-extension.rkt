#lang racket/base

(require rackunit
         json
         racket/port
         racket/string
         racket/list
         "../racket/heavymental-core/protocol.rkt"
         "../racket/heavymental-core/cell.rkt"
         "../racket/heavymental-core/extension.rkt")

;; Helper to clean state between source-path tracking tests
;; (reset-extensions! and get-extension-source-path imported from extension.rkt)

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
  (check-not-false (member "loader-test:counter" names))
  (check-not-false (member "loader-test:label" names))
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
  (check-not-false (findf (lambda (m)
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

;; ── Test: Source path tracking for live reload ──────────────────────────────

(test-case "load-extension! records source path for live reload"
  (reset-extensions!)
  (define test-desc
    (extension-descriptor
     'test-watch "Test Watch" '() '() '() '() #f #f))
  (with-output-to-string
    (lambda ()
      (load-extension-descriptor! test-desc "/tmp/test-ext.rkt")))
  (check-equal? (get-extension-source-path 'test-watch) "/tmp/test-ext.rkt")
  (with-output-to-string
    (lambda () (unload-extension! 'test-watch))))

(test-case "unload-extension! clears source path"
  (reset-extensions!)
  (define test-desc
    (extension-descriptor
     'test-watch2 "Test Watch 2" '() '() '() '() #f #f))
  (with-output-to-string
    (lambda ()
      (load-extension-descriptor! test-desc "/tmp/test-ext2.rkt")))
  (with-output-to-string
    (lambda () (unload-extension! 'test-watch2)))
  (check-false (get-extension-source-path 'test-watch2)))

(test-case "load-extension-descriptor! without source-path leaves path as #f"
  (reset-extensions!)
  (define test-desc
    (extension-descriptor
     'test-no-path "No Path" '() '() '() '() #f #f))
  (with-output-to-string
    (lambda ()
      (load-extension-descriptor! test-desc)))
  (check-false (get-extension-source-path 'test-no-path))
  (with-output-to-string
    (lambda () (unload-extension! 'test-no-path))))

(test-case "reset-extensions! clears source paths"
  (reset-extensions!)
  (define test-desc
    (extension-descriptor
     'test-reset-path "Reset Path" '() '() '() '() #f #f))
  (with-output-to-string
    (lambda ()
      (load-extension-descriptor! test-desc "/tmp/reset-test.rkt")))
  (check-equal? (get-extension-source-path 'test-reset-path) "/tmp/reset-test.rkt")
  (reset-extensions!)
  (check-false (get-extension-source-path 'test-reset-path)))

;; ── Integration: full extension lifecycle ────────────────────────────────

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
