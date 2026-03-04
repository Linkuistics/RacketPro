#lang racket/base

(require rackunit
         json
         racket/port
         racket/string
         "../racket/heavymental-core/protocol.rkt"
         "../racket/heavymental-core/cell.rkt")

;; ── Test 1: make-message creates valid JSON ──────────────────────────────────

(test-case "make-message creates valid JSON with type field"
  (define msg (make-message "cell:update"))
  (check-equal? (hash-ref msg 'type) "cell:update")
  (check-true (hash? msg)))

(test-case "make-message includes additional key-value pairs"
  (define msg (make-message "cell:update" 'name "counter" 'value 42))
  (check-equal? (message-type msg) "cell:update")
  (check-equal? (message-ref msg 'name) "counter")
  (check-equal? (message-ref msg 'value) 42))

(test-case "make-message with no extra fields has only type"
  (define msg (make-message "ping"))
  (check-equal? (message-type msg) "ping")
  (check-equal? (message-ref msg 'missing "default") "default"))

(test-case "make-message raises error on odd number of key-value arguments"
  (check-exn exn:fail?
             (lambda () (make-message "foo" 'key-without-value))))

;; ── Test 2: send-message! writes valid JSON line ─────────────────────────────

(test-case "send-message! writes a single JSON line to output port"
  (define output
    (with-output-to-string
      (lambda ()
        (send-message! (make-message "ping")))))
  ;; Must end with a newline
  (check-true (string? output))
  (check-true (> (string-length output) 0))
  (check-equal? (string-ref output (- (string-length output) 1)) #\newline))

(test-case "send-message! output parses back to equivalent message"
  (define output
    (with-output-to-string
      (lambda ()
        (send-message! (make-message "cell:update" 'name "score" 'value 99)))))
  (define parsed (string->jsexpr (string-trim output)))
  (check-equal? (hash-ref parsed 'type) "cell:update")
  (check-equal? (hash-ref parsed 'name) "score")
  (check-equal? (hash-ref parsed 'value) 99))

(test-case "send-message! writes exactly one newline-terminated line"
  (define output
    (with-output-to-string
      (lambda ()
        (send-message! (make-message "pong")))))
  ;; Split on newlines; the last element should be empty (trailing newline)
  (define lines (string-split output "\n"))
  (check-equal? (length lines) 1))

;; ── Test 3: read-message parses JSON line ────────────────────────────────────

(test-case "read-message parses a simple JSON line"
  (define input-str "{\"type\":\"ping\"}\n")
  (define msg
    (with-input-from-string input-str
      (lambda () (read-message))))
  (check-not-false msg)
  (check-equal? (message-type msg) "ping"))

(test-case "read-message parses a complex JSON line with multiple fields"
  (define input-str "{\"type\":\"event\",\"name\":\"increment\"}\n")
  (define msg
    (with-input-from-string input-str
      (lambda () (read-message))))
  (check-equal? (message-type msg) "event")
  (check-equal? (message-ref msg 'name) "increment"))

(test-case "read-message round-trips through send-message!"
  (define original (make-message "cell:update" 'name "total" 'value 7))
  (define wire
    (with-output-to-string
      (lambda () (send-message! original))))
  (define recovered
    (with-input-from-string wire
      (lambda () (read-message))))
  (check-equal? (message-type recovered) "cell:update")
  (check-equal? (message-ref recovered 'name) "total")
  (check-equal? (message-ref recovered 'value) 7))

;; ── Test 4: read-message handles empty/invalid input ────────────────────────

(test-case "read-message returns #f for an empty line"
  (define result
    (with-input-from-string "\n"
      (lambda () (read-message))))
  (check-false result))

(test-case "read-message returns #f for a whitespace-only line"
  (define result
    (with-input-from-string "   \n"
      (lambda () (read-message))))
  (check-false result))

(test-case "read-message returns eof at end-of-file"
  (define result
    (with-input-from-string ""
      (lambda () (read-message))))
  (check-true (eof-object? result)))

(test-case "read-message returns #f for invalid JSON"
  (define result
    (with-input-from-string "not-valid-json\n"
      (lambda () (read-message))))
  (check-false result))

(test-case "read-message returns #f for malformed JSON"
  (define result
    (with-input-from-string "{bad json\n"
      (lambda () (read-message))))
  (check-false result))

;; ── Test 5: cells track state and emit updates ───────────────────────────────

(test-case "define-cell creates a cell with the correct initial value"
  (define-cell test-alpha 100)
  (check-equal? (cell-ref 'test-alpha) 100))

(test-case "cell-ref retrieves the current value of a cell"
  (define-cell test-beta "hello")
  (check-equal? (cell-ref 'test-beta) "hello"))

(test-case "cell-ref raises error for unknown cell"
  (check-exn exn:fail?
             (lambda () (cell-ref 'no-such-cell-xyz))))

(test-case "cell-set! updates the stored value"
  (define-cell test-gamma 0)
  (with-output-to-string (lambda () (cell-set! 'test-gamma 42)))
  (check-equal? (cell-ref 'test-gamma) 42))

(test-case "cell-set! emits a cell:update message to stdout"
  (define-cell test-delta 0)
  (define output
    (with-output-to-string
      (lambda ()
        (cell-set! 'test-delta 77))))
  (define parsed (string->jsexpr (string-trim output)))
  (check-equal? (hash-ref parsed 'type) "cell:update")
  (check-equal? (hash-ref parsed 'name) "test-delta")
  (check-equal? (hash-ref parsed 'value) 77))

(test-case "cell-set! update message contains correct name as string"
  (define-cell test-epsilon "start")
  (define output
    (with-output-to-string
      (lambda ()
        (cell-set! 'test-epsilon "end"))))
  (define parsed (string->jsexpr (string-trim output)))
  (check-equal? (hash-ref parsed 'name) "test-epsilon")
  (check-equal? (hash-ref parsed 'value) "end"))

(test-case "cell-update! applies a function and emits updated value"
  (define-cell test-zeta 10)
  (define output
    (with-output-to-string
      (lambda ()
        (cell-update! 'test-zeta add1))))
  (check-equal? (cell-ref 'test-zeta) 11)
  (define parsed (string->jsexpr (string-trim output)))
  (check-equal? (hash-ref parsed 'type) "cell:update")
  (check-equal? (hash-ref parsed 'value) 11))

(test-case "cell-set! successive updates are reflected in cell-ref"
  (define-cell test-eta 0)
  (with-output-to-string
    (lambda ()
      (cell-set! 'test-eta 1)
      (cell-set! 'test-eta 2)
      (cell-set! 'test-eta 3)))
  (check-equal? (cell-ref 'test-eta) 3))

(test-case "all-cells returns a hash containing defined cells"
  (define-cell test-theta 999)
  (define cells (all-cells))
  (check-true (hash? cells))
  (check-true (hash-has-key? cells 'test-theta))
  (check-equal? (hash-ref cells 'test-theta) 999))

(displayln "All tests passed!")
