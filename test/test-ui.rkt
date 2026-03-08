#lang racket/base
(require rackunit
         racket/list
         "../racket/heavymental-core/ui.rkt")

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
