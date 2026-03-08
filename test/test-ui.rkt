#lang racket/base
(require rackunit
         racket/list
         racket/string
         "../racket/heavymental-core/ui.rkt"
         "../racket/heavymental-core/handler-registry.rkt")

;; Basic element
(test-case "ui: single element with no props"
  (define result (ui (editor)))
  (check-equal? (hash-ref result 'type) "editor")
  (check-equal? (hash-ref result 'children) '()))

;; Element with props
(test-case "ui: element with keyword props"
  (define result (ui (text #:content "hello" #:textStyle "mono")))
  (check-equal? (hash-ref result 'type) "text")
  (check-equal? (hash-ref (hash-ref result 'props) 'content) "hello")
  (check-equal? (hash-ref (hash-ref result 'props) 'textStyle) "mono"))

;; Nested elements
(test-case "ui: nested children"
  (define result (ui (vbox (text #:content "a") (text #:content "b"))))
  (check-equal? (hash-ref result 'type) "vbox")
  (define children (hash-ref result 'children))
  (check-equal? (length children) 2)
  (check-equal? (hash-ref (first children) 'type) "text")
  (check-equal? (hash-ref (second children) 'type) "text"))

;; Deeply nested
(test-case "ui: deeply nested tree"
  (define result
    (ui (vbox
          (hbox
            (button #:label "+1")
            (button #:label "-1"))
          (text #:content "result"))))
  (check-equal? (hash-ref result 'type) "vbox")
  (define children (hash-ref result 'children))
  (check-equal? (length children) 2)
  (define hbox-node (first children))
  (check-equal? (hash-ref hbox-node 'type) "hbox")
  (check-equal? (length (hash-ref hbox-node 'children)) 2))

;; Composable via unquote
(test-case "ui: unquote splices pre-built nodes"
  (define header (ui (toolbar)))
  (define result (ui (vbox ,header (editor))))
  (define children (hash-ref result 'children))
  (check-equal? (length children) 2)
  (check-equal? (hash-ref (first children) 'type) "toolbar"))

;; Element with cell reference in prop
(test-case "ui: cell reference in prop preserved"
  (define result (ui (text #:content "cell:counter")))
  (check-equal? (hash-ref (hash-ref result 'props) 'content) "cell:counter"))

;; ---- Handler auto-registration tests ----

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

;; ---- Handler cleanup tests ----

;; Test: collect-handler-ids finds _h: IDs in layout tree
(test-case "collect-handler-ids extracts handler IDs"
  (define layout
    (hasheq 'type "vbox"
            'props (hasheq)
            'children
            (list (hasheq 'type "button"
                          'props (hasheq 'on-click "_h:1" 'label "Go")
                          'children '())
                  (hasheq 'type "button"
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
