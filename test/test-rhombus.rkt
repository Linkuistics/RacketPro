#lang racket/base

(require rackunit
         json
         racket/file
         racket/port
         racket/string
         "../racket/heavymental-core/protocol.rkt"
         "../racket/heavymental-core/cell.rkt"
         "../racket/heavymental-core/editor.rkt"
         "../racket/heavymental-core/repl.rkt"
         "../racket/heavymental-core/lang-intel.rkt")

;; ── Helpers ──────────────────────────────────────────────────────────────────

(define (parse-all-messages output)
  (define lines (string-split (string-trim output) "\n"))
  (for/list ([line (in-list lines)]
             #:when (> (string-length (string-trim line)) 0))
    (string->jsexpr line)))

;; ── Ensure cells exist ──────────────────────────────────────────────────────
(define-cell current-file "untitled.rkt")
(define-cell file-dirty #f)
(define-cell title "HeavyMental")
(define-cell status "starting")

(define (reset-cells!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "untitled.rkt")
      (cell-set! 'file-dirty #f)
      (cell-set! 'title "HeavyMental")
      (cell-set! 'status "starting"))))

(define (make-temp-rhm-file content)
  (define tmp (make-temporary-file "rhm-test-~a.rhm"))
  (call-with-output-file tmp
    (lambda (out) (display content out))
    #:exists 'replace)
  tmp)

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: detect-language for Rhombus
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "detect-language returns rhombus for .rhm"
  (check-equal? (detect-language "demo.rhm") "rhombus")
  (check-equal? (detect-language "/home/user/code/main.rhm") "rhombus"))

(test-case "detect-lang-from-content returns rhombus for #lang rhombus"
  (check-equal? (detect-lang-from-content "#lang rhombus\ndef x = 42\n") "rhombus"))

(test-case "detect-lang-from-content returns #f for no #lang"
  (check-false (detect-lang-from-content "def x = 42\n")))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: analyze-source on Rhombus code
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "analyze-source on valid Rhombus code returns hash with results"
  (define result (analyze-source "/tmp/test.rhm"
                                 "#lang rhombus\ndef x = 42\nx\n"))
  (check-true (hash? result) "should return a hash")
  (check-true (hash-has-key? result 'diagnostics) "should have diagnostics key")
  (check-true (hash-has-key? result 'arrows) "should have arrows key")
  (check-true (hash-has-key? result 'hovers) "should have hovers key")
  (check-true (list? (hash-ref result 'diagnostics))))

(test-case "analyze-source on invalid Rhombus code returns diagnostics with errors"
  (define result (analyze-source "/tmp/bad.rhm"
                                 "#lang rhombus\ndef x =\n"))
  (define diags (hash-ref result 'diagnostics))
  (check-true (> (length diags) 0) "should have error diagnostics")
  (check-true (string? (hash-ref (car diags) 'message))
              "diagnostic should have error message"))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: REPL spawning for Rhombus
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "start-repl #:language rhombus emits pty:create with -I rhombus"
  (reset-cells!)
  (define output
    (with-output-to-string
      (lambda () (start-repl #:language "rhombus"))))
  (define msgs (parse-all-messages output))
  (define pty-msg (findf (lambda (m) (string=? (hash-ref m 'type) "pty:create")) msgs))
  (check-not-false pty-msg "pty:create should be present")
  (check-equal? (hash-ref pty-msg 'args) (list "-I" "rhombus")
                "should pass -I rhombus args"))

(displayln "All Rhombus tests passed!")
