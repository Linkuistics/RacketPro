#lang racket/base

(require rackunit
         json
         racket/file
         racket/port
         racket/string
         racket/list
         "../racket/heavymental-core/protocol.rkt"
         "../racket/heavymental-core/cell.rkt"
         "../racket/heavymental-core/macro-expander.rkt")

;; ── Helpers ──────────────────────────────────────────────────────────────────

;; Parse all JSON messages from a captured output string.
;; Each message is one newline-terminated JSON object.
(define (parse-all-messages output)
  (define lines (string-split (string-trim output) "\n"))
  (for/list ([line (in-list lines)]
             #:when (> (string-length (string-trim line)) 0))
    (string->jsexpr line)))

;; Find a message by type in a list of parsed messages.
(define (find-message-by-type msgs type)
  (findf (lambda (m) (string=? (hash-ref m 'type "") type)) msgs))

;; ── Ensure cells exist ──────────────────────────────────────────────────────
;; The macro-expander uses these cells; they must be registered before use.
(define-cell macro-active #f)
(define-cell current-bottom-tab "terminal")

;; Reset cells to known state before each test.
(define (reset-state!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'macro-active #f)
      (cell-set! 'current-bottom-tab "terminal"))))

;; Create a temporary .rkt file with the given content.
(define (make-temp-rkt-file content)
  (define tmp (make-temporary-file "macro-test-~a.rkt"))
  (call-with-output-file tmp
    (lambda (out) (display content out))
    #:exists 'replace)
  tmp)

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: start-macro-expander with simple macro (cond)
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "start-macro-expander produces macro:tree for cond expression"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda ()
        (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))

  ;; Should contain a macro:tree message
  (define tree-msg (find-message-by-type msgs "macro:tree"))
  (check-not-false tree-msg "macro:tree message should be present")
  (check-true (list? (hash-ref tree-msg 'forms))
              "macro:tree should contain a 'forms list")

  ;; macro-active cell should be #t
  (check-equal? (cell-ref 'macro-active) #t)
  ;; current-bottom-tab should be switched to "macros"
  (check-equal? (cell-ref 'current-bottom-tab) "macros")

  ;; Cleanup
  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

(test-case "start-macro-expander tree has correct structure"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda ()
        (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))
  (define tree-msg (find-message-by-type msgs "macro:tree"))
  (check-not-false tree-msg)

  ;; Each form in 'forms should be a hash with expected keys
  (define forms (hash-ref tree-msg 'forms))
  (check-true (> (length forms) 0) "should have at least one form")

  (define first-form (car forms))
  (check-true (hash-has-key? first-form 'id) "node should have 'id")
  (check-true (hash-has-key? first-form 'before) "node should have 'before")
  (check-true (hash-has-key? first-form 'children) "node should have 'children")

  ;; Cleanup
  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: start-macro-expander with simple, non-macro code
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "start-macro-expander works with non-macro code"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(+ 1 2)\n"))
  (define output
    (with-output-to-string
      (lambda ()
        (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))

  ;; Should still produce a macro:tree (with leaf nodes, no macro field)
  (define tree-msg (find-message-by-type msgs "macro:tree"))
  (check-not-false tree-msg "macro:tree should be sent even for non-macro code")

  ;; Cleanup
  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: start-macro-expander handles syntax errors gracefully
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "start-macro-expander sends macro:error for syntax errors"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(define x (+ 1\n"))
  (define output
    (with-output-to-string
      (lambda ()
        (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))

  ;; Should send macro:error, not crash
  (define error-msg (find-message-by-type msgs "macro:error"))
  (check-not-false error-msg "macro:error message should be present for syntax errors")
  (check-true (string? (hash-ref error-msg 'error ""))
              "macro:error should contain an error string")

  ;; After error, macro-active should be reset to #f (stop-macro-expander is called internally)
  (check-equal? (cell-ref 'macro-active) #f)

  (delete-file tmp))

(test-case "start-macro-expander does not crash on empty file"
  (reset-state!)
  (define tmp (make-temp-rkt-file ""))
  (check-not-exn
    (lambda ()
      (with-output-to-string
        (lambda ()
          (start-macro-expander (path->string tmp))))))
  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: stop-macro-expander
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "stop-macro-expander resets macro-active cell to #f"
  (reset-state!)
  ;; First start, then stop
  (define tmp (make-temp-rkt-file "#lang racket/base\n(+ 1 2)\n"))
  (with-output-to-string
    (lambda () (start-macro-expander (path->string tmp))))
  (check-equal? (cell-ref 'macro-active) #t)

  (with-output-to-string
    (lambda () (stop-macro-expander)))
  (check-equal? (cell-ref 'macro-active) #f)
  (delete-file tmp))

(test-case "stop-macro-expander sends macro:clear message"
  (reset-state!)
  (define output
    (with-output-to-string
      (lambda () (stop-macro-expander))))
  (define msgs (parse-all-messages output))
  (define clear-msg (find-message-by-type msgs "macro:clear"))
  (check-not-false clear-msg "macro:clear message should be sent"))

(test-case "stop-macro-expander can be called multiple times without crashing"
  (reset-state!)
  (check-not-exn
    (lambda ()
      (with-output-to-string
        (lambda ()
          (stop-macro-expander)
          (stop-macro-expander)
          (stop-macro-expander))))))

(test-case "stop-macro-expander can be called without prior start"
  (reset-state!)
  (check-not-exn
    (lambda ()
      (with-output-to-string
        (lambda ()
          (stop-macro-expander))))))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: start/stop round-trip
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "start then stop then start again works correctly"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(when #t 42)\n"))

  ;; First run
  (with-output-to-string
    (lambda () (start-macro-expander (path->string tmp))))
  (check-equal? (cell-ref 'macro-active) #t)

  ;; Stop
  (with-output-to-string
    (lambda () (stop-macro-expander)))
  (check-equal? (cell-ref 'macro-active) #f)

  ;; Second run should work fine
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))
  (define tree-msg (find-message-by-type msgs "macro:tree"))
  (check-not-false tree-msg "macro:tree should work on second invocation")
  (check-equal? (cell-ref 'macro-active) #t)

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

(displayln "All macro expander tests passed!")
