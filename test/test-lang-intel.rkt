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
  ;; An unmatched close-paren triggers a read error
  (define result (analyze-source "/tmp/bad.rkt" ")"))
  (define diags (hash-ref result 'diagnostics))
  (check-true (> (length diags) 0)))
