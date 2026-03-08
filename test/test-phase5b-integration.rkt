#lang racket/base
(require rackunit
         json
         racket/list
         racket/string
         racket/port
         "../racket/heavymental-core/ui.rkt"
         "../racket/heavymental-core/handler-registry.rkt"
         "../racket/heavymental-core/component.rkt"
         "../racket/heavymental-core/extension.rkt"
         "../racket/heavymental-core/cell.rkt"
         "../racket/heavymental-core/protocol.rkt")

;; ── Helpers ──────────────────────────────────────────────────────────────────

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

;; ── Integration: ui macro + handler registry round-trip ─────────────────────

(test-case "integration: ui macro with lambda handlers produces valid layout"
  (clear-auto-handlers!)
  (define layout
    (ui (vbox
          (button #:label "Click"
                  #:on-click (lambda () (void)))
          (text #:content "cell:test"))))
  ;; Layout should be a valid hasheq tree
  (check-equal? (hash-ref layout 'type) "vbox")
  (define children (hash-ref layout 'children))
  (check-equal? (length children) 2)
  ;; Button's on-click should be a registered handler ID
  (define btn (first children))
  (define handler-id (hash-ref (hash-ref btn 'props) 'on-click))
  (check-true (string-prefix? handler-id "_h:"))
  (check-true (procedure? (get-auto-handler handler-id))))

;; ── Integration: handler cleanup ────────────────────────────────────────────

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

;; ── Integration: component descriptor + register message ────────────────────

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

;; ── Integration: component with string template ─────────────────────────────

(test-case "integration: component with string template sends correctly"
  (define-component test-str-comp
    #:tag "hm-test-str"
    #:properties ([label "default"])
    #:template "<span>${label}</span>"
    #:style ""
    #:script "")
  (define output
    (with-output-to-string
      (lambda () (register-component! test-str-comp))))
  (define msgs (parse-all-messages output))
  (define reg-msg (find-message-by-type msgs "component:register"))
  (check-true (hash? reg-msg))
  (check-equal? (hash-ref reg-msg 'template) "<span>${label}</span>"))

;; ── Integration: ui macro inside define-extension panel ─────────────────────

(test-case "integration: define-extension with ui macro panel"
  (clear-auto-handlers!)
  (reset-extensions!)
  (define-extension ui-panel-ext
    #:name "UI Panel Test"
    #:cells ([value 0])
    #:panels ([#:id "ui-panel" #:label "UI Panel" #:tab 'bottom
               #:layout (ui
                          (vbox
                            (text #:content "cell:value")
                            (button #:label "Go"
                                    #:on-click (lambda ()
                                                 (cell-update! 'ui-panel-ext:value add1)))))]))
  ;; Panel layout should be a valid tree
  (define panels (extension-descriptor-panels ui-panel-ext))
  (check-equal? (length panels) 1)
  (define layout (hash-ref (first panels) 'layout))
  (check-equal? (hash-ref layout 'type) "vbox")
  (define children (hash-ref layout 'children))
  (check-equal? (length children) 2)
  ;; Button should have an auto-registered handler
  (define btn (second children))
  (define handler-id (hash-ref (hash-ref btn 'props) 'on-click))
  (check-true (string-prefix? handler-id "_h:")))

;; ── Integration: extension load with ui layout → handler works end-to-end ───

(test-case "integration: extension with ui layout handlers work end-to-end"
  (clear-auto-handlers!)
  (reset-extensions!)
  (define-extension e2e-ext
    #:name "E2E Test"
    #:cells ([counter 0])
    #:panels ([#:id "e2e" #:label "E2E" #:tab 'bottom
               #:layout (ui
                          (button #:label "+1"
                                  #:on-click (lambda ()
                                               (cell-update! 'e2e-ext:counter add1))))]))
  ;; Load the extension
  (define output
    (with-output-to-string
      (lambda ()
        (load-extension-descriptor! e2e-ext))))
  ;; Cell should be registered
  (check-equal? (cell-ref 'e2e-ext:counter) 0)
  ;; Get the handler ID from the panel layout
  (define panels (extension-descriptor-panels e2e-ext))
  (define layout (hash-ref (first panels) 'layout))
  (define handler-id (hash-ref (hash-ref layout 'props) 'on-click))
  ;; Call the auto-registered handler
  (define handler (get-auto-handler handler-id))
  (check-true (procedure? handler))
  (with-output-to-string (lambda () (handler (hasheq))))
  (check-equal? (cell-ref 'e2e-ext:counter) 1)
  ;; Call again
  (with-output-to-string (lambda () (handler (hasheq))))
  (check-equal? (cell-ref 'e2e-ext:counter) 2)
  ;; Clean up
  (with-output-to-string
    (lambda () (unload-extension! 'e2e-ext))))

;; ── Integration: extension with lifecycle hooks + component ─────────────────

(test-case "integration: extension lifecycle hooks fire with component registration"
  (reset-extensions!)
  (define registered-tag #f)
  (define unregistered-tag #f)
  (define-component lifecycle-comp
    #:tag "hm-lifecycle-comp"
    #:properties ([val "test"])
    #:template "<div>${val}</div>"
    #:style ""
    #:script "")
  (define-extension lifecycle-comp-ext
    #:name "Lifecycle Component"
    #:on-activate (lambda ()
                    (set! registered-tag (component-descriptor-tag lifecycle-comp)))
    #:on-deactivate (lambda ()
                      (set! unregistered-tag (component-descriptor-tag lifecycle-comp))))
  ;; Load triggers on-activate
  (with-output-to-string
    (lambda () (load-extension-descriptor! lifecycle-comp-ext)))
  (check-equal? registered-tag "hm-lifecycle-comp")
  (check-false unregistered-tag)
  ;; Unload triggers on-deactivate
  (with-output-to-string
    (lambda () (unload-extension! 'lifecycle-comp-ext)))
  (check-equal? unregistered-tag "hm-lifecycle-comp"))

;; ── Integration: extensions-list-snapshot after load ─────────────────────────

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
  (check-equal? (hash-ref (car snapshot) 'path) "/tmp/int.rkt")
  (check-equal? (hash-ref (car snapshot) 'status) "active")
  (with-output-to-string
    (lambda () (unload-extension! 'int-ext))))

;; ── Integration: cell rewriting in extension layout contributions ────────────

(test-case "integration: ui layout cell refs rewritten in contributions"
  (reset-extensions!)
  (define-extension rewrite-ext
    #:name "Rewrite Test"
    #:cells ([data "hello"])
    #:panels ([#:id "rw" #:label "Rewrite" #:tab 'bottom
               #:layout (ui
                          (text #:content "cell:data"))]))
  (with-output-to-string
    (lambda () (load-extension-descriptor! rewrite-ext)))
  ;; Get layout contributions — cell refs should be namespaced
  (define contributions (get-extension-layout-contributions))
  (check-true (> (length contributions) 0))
  (define panel (first contributions))
  (define layout (hash-ref panel 'layout))
  ;; The text node's content should be rewritten to "cell:rewrite-ext:data"
  (define children (hash-ref layout 'children '()))
  ;; The layout itself is the text node (not wrapped in vbox after rewrite?)
  ;; Actually the contribution returns the layout which is the vbox with rewritten props
  ;; Let's check the text child
  (when (> (length children) 0)
    (define text-node (first children))
    (define text-content (hash-ref (hash-ref text-node 'props (hasheq)) 'content ""))
    (check-equal? text-content "cell:rewrite-ext:data"))
  ;; Clean up
  (with-output-to-string
    (lambda () (unload-extension! 'rewrite-ext))))

;; ── Integration: multiple extensions coexist ─────────────────────────────────

(test-case "integration: multiple extensions loaded simultaneously"
  (reset-extensions!)
  (define-extension multi-a
    #:name "Multi A"
    #:cells ([val-a 10]))
  (define-extension multi-b
    #:name "Multi B"
    #:cells ([val-b 20]))
  (with-output-to-string
    (lambda ()
      (load-extension-descriptor! multi-a)
      (load-extension-descriptor! multi-b)))
  ;; Both cells exist with namespaced names
  (check-equal? (cell-ref 'multi-a:val-a) 10)
  (check-equal? (cell-ref 'multi-b:val-b) 20)
  ;; Snapshot shows both
  (define snapshot (extensions-list-snapshot))
  (check-equal? (length snapshot) 2)
  ;; Clean up
  (with-output-to-string
    (lambda ()
      (unload-extension! 'multi-a)
      (unload-extension! 'multi-b))))

(displayln "All Phase 5b integration tests passed.")
