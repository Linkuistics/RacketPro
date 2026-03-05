#lang racket/base

(require rackunit
         json
         racket/port
         racket/string
         racket/list
         racket/file
         "../racket/heavymental-core/protocol.rkt"
         "../racket/heavymental-core/cell.rkt"
         "../racket/heavymental-core/stepper.rkt")

;; ── Helpers ──────────────────────────────────────────────────────

(define (parse-all-messages output)
  (define lines (string-split (string-trim output) "\n"))
  (for/list ([line (in-list lines)]
             #:when (> (string-length (string-trim line)) 0))
    (string->jsexpr line)))

(define (filter-by-type msgs type)
  (filter (lambda (m) (equal? (hash-ref m 'type #f) type)) msgs))

;; Helper: write a temp Racket file, run stepper in continue mode, return parsed messages.
;; Uses stepper-continue to run to completion (backward compat with existing tests).
(define (run-stepper-on-source source-text)
  (define tmp (make-temporary-file "stepper-test-~a.rkt"))
  (with-output-to-file tmp #:exists 'replace
    (lambda () (display source-text)))
  (define output
    (with-output-to-string
      (lambda ()
        (start-stepper (path->string tmp))
        ;; Immediately switch to continue mode so it runs to completion
        (stepper-continue)
        ;; Wait for stepper thread to finish
        (sleep 5))))
  (delete-file tmp)
  (parse-all-messages output))

;; Helper: start stepper in interactive (step) mode, return the temp file path.
;; Caller is responsible for advancing steps and cleaning up.
(define (start-stepper-interactive source-text)
  (define tmp (make-temporary-file "stepper-test-~a.rkt"))
  (with-output-to-file tmp #:exists 'replace
    (lambda () (display source-text)))
  (start-stepper (path->string tmp))
  tmp)

;; ── Cells needed by the stepper ──────────────────────────────────

(define-cell stepper-active #f)
(define-cell stepper-step 0)
(define-cell stepper-total -1)
(define-cell status "Ready")

;; ── Tests ────────────────────────────────────────────────────────

(test-case "stepper-active? starts as false"
  (check-false (stepper-active?)))

(test-case "stop-stepper when not running emits stepper:finished"
  (define output
    (with-output-to-string
      (lambda () (stop-stepper))))
  (define msgs (parse-all-messages output))
  (define finished (filter-by-type msgs "stepper:finished"))
  (check-equal? (length finished) 1)
  (check-equal? (hash-ref (car finished) 'total) 0))

(test-case "stepper produces at least one step for (+ 1 2)"
  (define msgs
    (run-stepper-on-source "#lang racket\n(+ 1 2)\n"))

  ;; Should have at least one stepper:step message
  (define step-msgs (filter-by-type msgs "stepper:step"))
  (check-true (> (length step-msgs) 0)
              "Expected at least one stepper:step message")

  ;; First step should have before/after data
  (define first-step (car step-msgs))
  (define data (hash-ref first-step 'data))
  (check-equal? (hash-ref data 'type) "before-after")
  (check-true (list? (hash-ref data 'before)))
  (check-true (list? (hash-ref data 'after)))

  ;; Should have finished with stepper:finished
  (define finished (filter-by-type msgs "stepper:finished"))
  (check-true (> (length finished) 0)
              "Expected stepper:finished message"))

(test-case "stepper shows (+ 1 2) -> 3"
  (define msgs
    (run-stepper-on-source "#lang racket\n(+ 1 2)\n"))

  (define step-msgs (filter-by-type msgs "stepper:step"))
  (check-equal? (length step-msgs) 1)

  (define data (hash-ref (car step-msgs) 'data))
  (check-equal? (hash-ref data 'before) (list "(+ 1 2)"))
  (check-equal? (hash-ref data 'after) (list "3")))

(test-case "stepper produces multiple steps for variable substitution"
  (define msgs
    (run-stepper-on-source
     "#lang racket\n(define x 10)\n(* x 3)\n"))

  (define step-msgs (filter-by-type msgs "stepper:step"))
  ;; Should have at least 2 steps:
  ;;   (* x 3) -> (* 10 3) and (* 10 3) -> 30
  (check-true (>= (length step-msgs) 2)
              (format "Expected >= 2 steps, got ~a" (length step-msgs)))

  ;; Steps should be numbered sequentially
  (for ([m (in-list step-msgs)]
        [i (in-naturals 1)])
    (check-equal? (hash-ref m 'step) i
                  (format "Step ~a should have step number ~a" i i))))

(test-case "stepper step includes source position info"
  (define msgs
    (run-stepper-on-source "#lang racket\n(+ 1 2)\n"))

  (define step-msgs (filter-by-type msgs "stepper:step"))
  (check-true (> (length step-msgs) 0))

  (define data (hash-ref (car step-msgs) 'data))
  (define pre-src (hash-ref data 'pre_src))
  (check-true (hash? pre-src) "pre_src should be a hash")
  (check-true (hash-has-key? pre-src 'position) "pre_src should have position")
  (check-true (hash-has-key? pre-src 'span) "pre_src should have span")
  (check-true (number? (hash-ref pre-src 'position)))
  (check-true (number? (hash-ref pre-src 'span))))

(test-case "stepper:finished includes total step count"
  (define msgs
    (run-stepper-on-source "#lang racket\n(+ 1 2)\n"))

  (define finished (filter-by-type msgs "stepper:finished"))
  (check-equal? (length finished) 1)
  (check-equal? (hash-ref (car finished) 'total) 1))

(test-case "stepper handles multi-expression programs"
  (define msgs
    (run-stepper-on-source
     "#lang racket\n(define x 10)\n(define y (* x 3))\n(+ x y)\n"))

  (define step-msgs (filter-by-type msgs "stepper:step"))
  ;; Multiple reductions expected for variable substitutions
  (check-true (>= (length step-msgs) 3)
              (format "Expected >= 3 steps, got ~a" (length step-msgs)))

  (define finished (filter-by-type msgs "stepper:finished"))
  (check-equal? (length finished) 1)
  (check-equal? (hash-ref (car finished) 'total) (length step-msgs)))

(test-case "stepper reports errors for bad programs"
  (define msgs
    (run-stepper-on-source "#lang racket\n(/ 1 0)\n"))

  ;; Should have a stepper:error message
  (define error-msgs (filter-by-type msgs "stepper:error"))
  (check-true (> (length error-msgs) 0)
              "Expected stepper:error message for division by zero")

  (define err (car error-msgs))
  (check-true (string? (hash-ref err 'error))
              "Error message should be a string"))

(test-case "stepper reports error for nonexistent file"
  (define output
    (with-output-to-string
      (lambda ()
        (start-stepper "/tmp/nonexistent-stepper-file-12345.rkt")
        ;; Continue in case it pauses (it won't for errors, but be safe)
        (stepper-continue)
        (sleep 2))))

  (define msgs (parse-all-messages output))
  (define error-msgs (filter-by-type msgs "stepper:error"))
  (check-true (> (length error-msgs) 0)
              "Expected stepper:error for missing file"))

(test-case "stepper step kind is reported"
  (define msgs
    (run-stepper-on-source "#lang racket\n(+ 1 2)\n"))

  (define step-msgs (filter-by-type msgs "stepper:step"))
  (check-true (> (length step-msgs) 0))

  (define data (hash-ref (car step-msgs) 'data))
  (check-true (string? (hash-ref data 'kind))
              "Step should include kind field"))

(test-case "stepper updates cells during stepping"
  ;; Reset cell state
  (cell-set! 'stepper-active #f)
  (cell-set! 'stepper-step 0)

  (define msgs
    (run-stepper-on-source "#lang racket\n(+ 1 2)\n"))

  ;; Check that cell:update messages were sent for stepper-active
  (define cell-updates (filter-by-type msgs "cell:update"))
  (define active-updates
    (filter (lambda (m) (equal? (hash-ref m 'name #f) "stepper-active"))
            cell-updates))

  ;; Should have at least 2 updates: set to true, then set to false
  (check-true (>= (length active-updates) 2)
              "Expected stepper-active cell to be updated at least twice"))

;; ── Bindings extraction tests ────────────────────────────────────

(test-case "extract-define-binding recognizes simple numeric define"
  (check-equal? (extract-define-binding "(define x 10)")
                (list "x" "10"))
  (check-equal? (extract-define-binding "(define y -3)")
                (list "y" "-3"))
  (check-equal? (extract-define-binding "(define z 3.14)")
                (list "z" "3.14")))

(test-case "extract-define-binding recognizes string and boolean defines"
  (check-equal? (extract-define-binding "(define s \"hello\")")
                (list "s" "\"hello\""))
  (check-equal? (extract-define-binding "(define flag #t)")
                (list "flag" "#t"))
  (check-equal? (extract-define-binding "(define off #f)")
                (list "off" "#f")))

(test-case "extract-define-binding recognizes quoted values"
  (check-equal? (extract-define-binding "(define sym 'foo)")
                (list "sym" "'foo"))
  (check-equal? (extract-define-binding "(define lst '(1 2 3))")
                (list "lst" "'(1 2 3)")))

(test-case "extract-define-binding rejects non-literal bodies"
  ;; A define with a compound expression as body should NOT be extracted
  (check-false (extract-define-binding "(define x (+ 1 2))"))
  (check-false (extract-define-binding "(define y (* x 3))"))
  ;; Not a define at all
  (check-false (extract-define-binding "(+ 1 2)"))
  (check-false (extract-define-binding "42")))

(test-case "stepper includes bindings field in step data"
  (define msgs
    (run-stepper-on-source "#lang racket\n(define x 10)\n(+ x 3)\n"))

  (define step-msgs (filter-by-type msgs "stepper:step"))
  (check-true (> (length step-msgs) 0))

  ;; Every before-after step should have a bindings field (possibly empty list)
  (for ([m (in-list step-msgs)])
    (define data (hash-ref m 'data))
    (when (equal? (hash-ref data 'type #f) "before-after")
      (check-true (list? (hash-ref data 'bindings))
                  "before-after steps should include bindings list"))))

(test-case "stepper includes bindings for define forms"
  (define msgs
    (run-stepper-on-source "#lang racket\n(define x 10)\n(+ x 3)\n"))

  (define step-msgs (filter-by-type msgs "stepper:step"))
  ;; At least one step should have bindings with x -> 10
  (check-true
   (ormap (lambda (m)
            (define data (hash-ref m 'data))
            (define bindings (hash-ref data 'bindings (list)))
            (ormap (lambda (b)
                     (and (equal? (hash-ref b 'name) "x")
                          (equal? (hash-ref b 'value) "10")))
                   bindings))
          step-msgs)
   "Expected at least one step with binding x=10"))

(test-case "stepper accumulates bindings across multiple defines"
  (define msgs
    (run-stepper-on-source
     "#lang racket\n(define x 10)\n(define y 20)\n(+ x y)\n"))

  (define step-msgs (filter-by-type msgs "stepper:step"))
  ;; The last step should have both x and y bindings
  (define last-ba-step
    (last (filter (lambda (m)
                    (equal? (hash-ref (hash-ref m 'data) 'type #f)
                            "before-after"))
                  step-msgs)))
  (define bindings (hash-ref (hash-ref last-ba-step 'data) 'bindings))
  (define binding-names (map (lambda (b) (hash-ref b 'name)) bindings))
  (check-not-false (member "x" binding-names)
                   "Last step should include binding for x")
  (check-not-false (member "y" binding-names)
                   "Last step should include binding for y"))

;; ── Interactive stepping tests ───────────────────────────────────

(test-case "stepper pauses after first step in step mode"
  ;; Start stepper interactively on a multi-step program
  (define output
    (with-output-to-string
      (lambda ()
        (define tmp (start-stepper-interactive
                     "#lang racket\n(define x 10)\n(* x 3)\n"))
        ;; Give the stepper thread time to produce its first step and block
        (sleep 1)
        ;; Should be active and paused after first step
        (check-true (stepper-active?)
                    "Stepper should still be active (paused)")
        ;; Stop the stepper to clean up
        (stop-stepper)
        (delete-file tmp))))

  ;; Parse messages: should have exactly 1 step (paused after it)
  ;; plus cell:update messages and the stepper:finished from stop-stepper
  (define msgs (parse-all-messages output))
  (define step-msgs (filter-by-type msgs "stepper:step"))
  (check-equal? (length step-msgs) 1
                "Expected exactly 1 step before stepper paused"))

(test-case "stepper-forward advances to next step"
  (define output
    (with-output-to-string
      (lambda ()
        (define tmp (start-stepper-interactive
                     "#lang racket\n(define x 10)\n(* x 3)\n"))
        ;; Wait for first step
        (sleep 1)
        ;; Advance one step
        (stepper-forward)
        ;; Wait for second step
        (sleep 1)
        ;; Clean up
        (stop-stepper)
        (delete-file tmp))))

  (define msgs (parse-all-messages output))
  (define step-msgs (filter-by-type msgs "stepper:step"))
  ;; Should have 2 steps (first auto, second from forward)
  (check-equal? (length step-msgs) 2
                (format "Expected 2 steps, got ~a" (length step-msgs))))

(test-case "stepper-back replays previous step from history"
  (define output
    (with-output-to-string
      (lambda ()
        (define tmp (start-stepper-interactive
                     "#lang racket\n(define x 10)\n(* x 3)\n"))
        ;; Wait for first step
        (sleep 1)
        ;; Advance to second step
        (stepper-forward)
        (sleep 1)
        ;; Go back to first step
        (stepper-back)
        ;; Clean up
        (stop-stepper)
        (delete-file tmp))))

  (define msgs (parse-all-messages output))
  (define step-msgs (filter-by-type msgs "stepper:step"))
  ;; Should have 3 step messages: step 1, step 2, step 1 (replayed)
  (check-equal? (length step-msgs) 3
                (format "Expected 3 step messages, got ~a" (length step-msgs)))
  ;; The third step message should be step 1 (replayed)
  (check-equal? (hash-ref (caddr step-msgs) 'step) 1
                "Third step message should be step 1 (back)"))

(test-case "stepper-forward replays next history step after back"
  (define output
    (with-output-to-string
      (lambda ()
        (define tmp (start-stepper-interactive
                     "#lang racket\n(define x 10)\n(* x 3)\n"))
        ;; Wait for first step
        (sleep 1)
        ;; Advance to second step
        (stepper-forward)
        (sleep 1)
        ;; Go back to first step
        (stepper-back)
        ;; Go forward again (replays step 2 from history)
        (stepper-forward)
        ;; Clean up
        (stop-stepper)
        (delete-file tmp))))

  (define msgs (parse-all-messages output))
  (define step-msgs (filter-by-type msgs "stepper:step"))
  ;; step 1, step 2, step 1 (back), step 2 (forward replay)
  (check-equal? (length step-msgs) 4
                (format "Expected 4 step messages, got ~a" (length step-msgs)))
  ;; Fourth message should be step 2 replayed
  (check-equal? (hash-ref (list-ref step-msgs 3) 'step) 2
                "Fourth step message should be step 2 (forward replay)"))

(test-case "stepper-continue runs to completion"
  (define output
    (with-output-to-string
      (lambda ()
        (define tmp (start-stepper-interactive
                     "#lang racket\n(define x 10)\n(* x 3)\n"))
        ;; Wait for first step
        (sleep 1)
        ;; Continue to finish
        (stepper-continue)
        (sleep 3)
        (delete-file tmp))))

  (define msgs (parse-all-messages output))
  (define step-msgs (filter-by-type msgs "stepper:step"))
  ;; Should have all steps (>= 2)
  (check-true (>= (length step-msgs) 2)
              (format "Expected >= 2 steps after continue, got ~a"
                      (length step-msgs)))
  ;; Should have stepper:finished
  (define finished (filter-by-type msgs "stepper:finished"))
  (check-equal? (length finished) 1
                "Expected stepper:finished after continue"))

(test-case "stepper-back does nothing at step 1"
  (define output
    (with-output-to-string
      (lambda ()
        (define tmp (start-stepper-interactive
                     "#lang racket\n(+ 1 2)\n"))
        ;; Wait for first step
        (sleep 1)
        ;; Try to go back (should have no effect)
        (stepper-back)
        ;; Clean up
        (stop-stepper)
        (delete-file tmp))))

  (define msgs (parse-all-messages output))
  (define step-msgs (filter-by-type msgs "stepper:step"))
  ;; Should have exactly 1 step (the initial one, no replay)
  (check-equal? (length step-msgs) 1
                "stepper-back at step 1 should produce no extra messages"))

(displayln "All stepper tests passed!")
