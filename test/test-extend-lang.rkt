#lang racket/base
(require rackunit
         racket/port
         racket/runtime-path)

;; ── Parser tests ────────────────────────────────────────────────────────────

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
         (vbox (text #:content "cell:count")))
       (event increment (cell-update! 'count add1))
       (menu "Tools" "Run" "Cmd+R" run-action)
       (on-activate (displayln "loaded"))
       (on-deactivate (displayln "unloaded")))))
  (check-equal? (hash-ref result 'name) "Full")
  (check-equal? (length (hash-ref result 'cells)) 2)
  (check-equal? (length (hash-ref result 'panels)) 1)
  (check-equal? (length (hash-ref result 'events)) 1)
  (check-equal? (length (hash-ref result 'menus)) 1))

(test-case "parse-extend: cells preserve order and values"
  (define result
    (parse-extend-source
     '((name: "Order")
       (cell a = 1)
       (cell b = "two")
       (cell c = #t))))
  (define cells (hash-ref result 'cells))
  (check-equal? (length cells) 3)
  (check-equal? (car (list-ref cells 0)) 'a)
  (check-equal? (cadr (list-ref cells 0)) 1)
  (check-equal? (car (list-ref cells 1)) 'b)
  (check-equal? (cadr (list-ref cells 1)) "two")
  (check-equal? (car (list-ref cells 2)) 'c)
  (check-equal? (cadr (list-ref cells 2)) #t))

(test-case "parse-extend: name-only extension"
  (define result
    (parse-extend-source
     '((name: "Minimal"))))
  (check-equal? (hash-ref result 'name) "Minimal")
  (check-equal? (hash-ref result 'cells) '())
  (check-equal? (hash-ref result 'panels) '())
  (check-equal? (hash-ref result 'events) '())
  (check-equal? (hash-ref result 'menus) '())
  (check-equal? (hash-ref result 'on-activate) #f)
  (check-equal? (hash-ref result 'on-deactivate) #f))

;; ── Reader tests ────────────────────────────────────────────────────────────

(require (prefix-in reader: "../racket/heavymental-core/extend/lang/reader.rkt"))

(test-case "reader: produces well-formed module syntax"
  (define src (open-input-string
               "(name: \"Hello\")\n(cell x = 42)\n"))
  (define stx (reader:read-syntax "test.rkt" src))
  (check-pred syntax? stx)
  (define datum (syntax->datum stx))
  ;; Should be (module id racket/base ...)
  (check-equal? (car datum) 'module)
  (check-equal? (cadr datum) 'hello)
  (check-equal? (caddr datum) 'racket/base))

(test-case "reader: derives module name from extension name"
  (define src (open-input-string
               "(name: \"My Cool Extension\")\n"))
  (define stx (reader:read-syntax "test.rkt" src))
  (define datum (syntax->datum stx))
  (check-equal? (cadr datum) 'my-cool-extension))

(test-case "reader: read produces datum"
  (define src (open-input-string
               "(name: \"Test\")\n(cell count = 0)\n"))
  (define datum (reader:read src))
  (check-pred list? datum)
  (check-equal? (car datum) 'module))
