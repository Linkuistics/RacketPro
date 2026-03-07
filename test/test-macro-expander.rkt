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

(define (parse-all-messages output)
  (define lines (string-split (string-trim output) "\n"))
  (for/list ([line (in-list lines)]
             #:when (> (string-length (string-trim line)) 0))
    (string->jsexpr line)))

(define (find-message-by-type msgs type)
  (findf (lambda (m) (string=? (hash-ref m 'type "") type)) msgs))

(define (find-all-messages-by-type msgs type)
  (filter (lambda (m) (string=? (hash-ref m 'type "") type)) msgs))

;; ── Ensure cells exist ──────────────────────────────────────────────────────
(define-cell macro-active #f)
(define-cell current-bottom-tab "terminal")

(define (reset-state!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'macro-active #f)
      (cell-set! 'current-bottom-tab "terminal"))))

(define (make-temp-rkt-file content)
  (define tmp (make-temporary-file "macro-test-~a.rkt"))
  (call-with-output-file tmp
    (lambda (out) (display content out))
    #:exists 'replace)
  tmp)

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: macro:steps message structure
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "start-macro-expander emits macro:steps for cond expression"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))

  ;; Should contain a macro:steps message
  (define steps-msg (find-message-by-type msgs "macro:steps"))
  (check-not-false steps-msg "macro:steps message should be present")
  (check-true (list? (hash-ref steps-msg 'steps))
              "macro:steps should contain a 'steps list")
  (check-true (> (length (hash-ref steps-msg 'steps)) 0)
              "should have at least one step")

  ;; macro-active cell should be #t
  (check-equal? (cell-ref 'macro-active) #t)
  ;; current-bottom-tab should be switched to "macros"
  (check-equal? (cell-ref 'current-bottom-tab) "macros")

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

(test-case "each step has expected fields"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))
  (define steps-msg (find-message-by-type msgs "macro:steps"))
  (define steps (hash-ref steps-msg 'steps))
  (define first-step (car steps))

  ;; Required fields
  (check-true (hash-has-key? first-step 'id) "step should have 'id")
  (check-true (hash-has-key? first-step 'type) "step should have 'type")
  (check-true (hash-has-key? first-step 'typeLabel) "step should have 'typeLabel")
  (check-true (hash-has-key? first-step 'before) "step should have 'before")
  (check-true (hash-has-key? first-step 'after) "step should have 'after")
  (check-true (hash-has-key? first-step 'foci) "step should have 'foci")
  (check-true (hash-has-key? first-step 'fociAfter) "step should have 'fociAfter")

  ;; First step for cond should be a macro step
  (check-equal? (hash-ref first-step 'type) "macro"
                "first step of cond expansion should be type 'macro'")

  ;; 'before' should be a string containing "cond"
  (check-true (string-contains? (hash-ref first-step 'before) "cond")
              "before text should contain 'cond'")

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

(test-case "macro steps include macro name"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))
  (define steps (hash-ref (find-message-by-type msgs "macro:steps") 'steps))

  ;; Find a macro-type step
  (define macro-steps (filter (lambda (s) (string=? (hash-ref s 'type "") "macro")) steps))
  (check-true (> (length macro-steps) 0) "should have at least one macro step")

  (define first-macro (car macro-steps))
  (check-true (hash-has-key? first-macro 'macro) "macro step should have 'macro field")
  (check-true (string? (hash-ref first-macro 'macro)) "macro name should be a string")

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

(test-case "foci contain offset/span pairs"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))
  (define steps (hash-ref (find-message-by-type msgs "macro:steps") 'steps))
  (define first-step (car steps))
  (define foci (hash-ref first-step 'foci))

  ;; Foci should be a list
  (check-true (list? foci) "foci should be a list")
  ;; Each focus item should have offset and span
  (when (> (length foci) 0)
    (define f (car foci))
    (check-true (hash-has-key? f 'offset) "focus should have 'offset")
    (check-true (hash-has-key? f 'span) "focus should have 'span"))

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: non-macro code
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "start-macro-expander works with non-macro code"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(+ 1 2)\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))

  ;; Should still produce macro:steps (may have tag steps but no macro steps)
  (define steps-msg (find-message-by-type msgs "macro:steps"))
  (check-not-false steps-msg "macro:steps should be sent even for non-macro code")

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: error handling
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "start-macro-expander sends macro:error for syntax errors"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(define x (+ 1\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))

  (define error-msg (find-message-by-type msgs "macro:error"))
  (check-not-false error-msg "macro:error message should be present for syntax errors")
  (check-true (string? (hash-ref error-msg 'error ""))
              "macro:error should contain an error string")
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

(test-case "start then stop then start again works correctly"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(when #t 42)\n"))

  (with-output-to-string
    (lambda () (start-macro-expander (path->string tmp))))
  (check-equal? (cell-ref 'macro-active) #t)

  (with-output-to-string
    (lambda () (stop-macro-expander)))
  (check-equal? (cell-ref 'macro-active) #f)

  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))
  (define steps-msg (find-message-by-type msgs "macro:steps"))
  (check-not-false steps-msg "macro:steps should work on second invocation")
  (check-equal? (cell-ref 'macro-active) #t)

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: step filtering
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "steps include only rewrite steps by default"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))
  (define steps (hash-ref (find-message-by-type msgs "macro:steps") 'steps))

  ;; All steps should have a valid type (only rewrite step types)
  (for ([s steps])
    (check-not-false (member (hash-ref s 'type)
                             '("macro" "tag-module-begin" "tag-app" "tag-datum"
                               "tag-top" "finish-block" "finish-expr" "block->letrec"
                               "splice-block" "splice-module" "splice-lifts"
                               "splice-end-lifts" "capture-lifts" "provide"
                               "finish-lsv"))
                     (format "unexpected step type: ~a" (hash-ref s 'type))))

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: macro-only filter
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "macro-only filter excludes tag and rename steps"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp) #:macro-only? #t))))
  (define msgs (parse-all-messages output))
  (define steps (hash-ref (find-message-by-type msgs "macro:steps") 'steps))

  ;; All steps should be of type "macro"
  (for ([s steps])
    (check-equal? (hash-ref s 'type) "macro"
                  (format "expected macro, got ~a" (hash-ref s 'type))))

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: macro:tree message
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "start-macro-expander emits macro:tree alongside macro:steps"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))

  ;; Should have both macro:steps and macro:tree
  (check-not-false (find-message-by-type msgs "macro:steps"))
  (check-not-false (find-message-by-type msgs "macro:tree"))

  (define tree-msg (find-message-by-type msgs "macro:tree"))
  (define forms (hash-ref tree-msg 'forms))
  (check-true (list? forms))
  (check-true (> (length forms) 0))

  ;; Each tree node should have id, label, children
  (define first-form (car forms))
  (check-true (hash-has-key? first-form 'id))
  (check-true (hash-has-key? first-form 'label))
  (check-true (hash-has-key? first-form 'children))

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: macro:pattern messages
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "macro:pattern emitted for syntax-parse macros"
  (reset-state!)
  ;; Create a file that defines and uses a syntax-parse macro
  (define macro-file (make-temp-rkt-file
    (string-append
      "#lang racket/base\n"
      "(require syntax/parse/define)\n"
      "(define-syntax-parse-rule (my-when test:expr body:expr ...)\n"
      "  (if test (begin body ...) (void)))\n"
      "(my-when #t (displayln \"hi\"))\n")))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string macro-file)))))
  (define msgs (parse-all-messages output))

  ;; Should have a macro:pattern message
  (define pattern-msgs (find-all-messages-by-type msgs "macro:pattern"))
  (check-true (> (length pattern-msgs) 0) "should emit at least one macro:pattern")

  (define first-pattern (car pattern-msgs))
  (check-true (hash-has-key? first-pattern 'pattern))
  (check-true (hash-has-key? first-pattern 'variables))
  (check-true (string-contains? (hash-ref first-pattern 'pattern) "my-when"))

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file macro-file))

(test-case "no macro:pattern for built-in macros"
  (reset-state!)
  (define tmp (make-temp-rkt-file "#lang racket/base\n(cond [#t 1] [else 2])\n"))
  (define output
    (with-output-to-string
      (lambda () (start-macro-expander (path->string tmp)))))
  (define msgs (parse-all-messages output))

  ;; Should NOT have macro:pattern for built-in cond
  (define pattern-msgs (find-all-messages-by-type msgs "macro:pattern"))
  (check-equal? (length pattern-msgs) 0
                "should not emit macro:pattern for built-in macros")

  (with-output-to-string (lambda () (stop-macro-expander)))
  (delete-file tmp))

(displayln "All macro expander tests passed!")
