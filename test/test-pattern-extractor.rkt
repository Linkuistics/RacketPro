#lang racket/base

(require rackunit
         racket/file
         racket/list
         racket/port
         racket/string
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

(test-case "extract-pattern handles define-syntax-rule"
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
  (check-not-false (member "test" var-names) "should include 'test' variable")
  (check-not-false (member "body" var-names) "should include 'body' variable")
  (delete-file tmp))

(displayln "All pattern extractor tests passed!")
