#lang racket/base

(require rackunit
         json
         racket/port
         racket/string
         racket/list
         racket/runtime-path)

;; ═══════════════════════════════════════════════════════════════════════════
;; E2E Protocol Tests — Subprocess integration tests for HeavyMental
;;
;; Spawns main.rkt as a real subprocess, pipes JSON through stdin/stdout,
;; and verifies the full message protocol — the same way Rust talks to it.
;; ═══════════════════════════════════════════════════════════════════════════

(define-runtime-path main-rkt "../racket/heavymental-core/main.rkt")

;; ── Subprocess helpers ───────────────────────────────────────────────────

;; Spawn main.rkt as subprocess.
;; Returns (values process from-racket to-racket)
;;   from-racket: input port  — read JSON messages from subprocess stdout
;;   to-racket:   output port — write JSON messages to subprocess stdin
;; Subprocess stderr goes to test runner stderr (visible in raco test output).
(define (spawn-main)
  (define racket-exe (find-executable-path "racket"))
  (unless racket-exe
    (error 'spawn-main "racket executable not found on PATH"))
  (define-values (proc out in _err)
    (subprocess #f #f (current-error-port)
                racket-exe (path->string main-rkt)))
  (values proc out in))

;; Read one JSON message from port with timeout (seconds).
;; Returns parsed hasheq or #f on timeout/error/eof.
(define (read-json-msg port [timeout 5])
  (define ch (make-channel))
  (define t
    (thread
     (lambda ()
       (with-handlers ([exn:fail? (lambda (_) (channel-put ch 'error))])
         (channel-put ch (read-line port 'linefeed))))))
  (define result (sync/timeout timeout ch))
  (cond
    [(not result) (kill-thread t) #f]
    [(or (eof-object? result) (eq? result 'error)) #f]
    [else
     (define trimmed (string-trim result))
     (and (not (string=? trimmed ""))
          (with-handlers ([exn:fail? (lambda (_) #f)])
            (string->jsexpr trimmed)))]))

;; Read messages until predicate matches or timeout.
;; Returns list of all collected messages.
(define (read-until port pred [timeout 10])
  (define deadline (+ (current-inexact-milliseconds) (* timeout 1000.0)))
  (let loop ([acc '()])
    (define remaining (/ (- deadline (current-inexact-milliseconds)) 1000.0))
    (if (<= remaining 0)
        (reverse acc)
        (let ([msg (read-json-msg port (max 0.1 remaining))])
          (if msg
              (let ([new-acc (cons msg acc)])
                (if (pred msg)
                    (reverse new-acc)
                    (loop new-acc)))
              (reverse acc))))))

;; Send a JSON message (hasheq) to the subprocess stdin.
(define (send-json! port msg)
  (write-json msg port)
  (newline port)
  (flush-output port))

;; Predicate builder: message has given type
(define ((type=? type) msg)
  (equal? (hash-ref msg 'type #f) type))

;; Find first message of a given type in a list
(define (find-msg type msgs)
  (findf (type=? type) msgs))

;; Find all messages of a given type in a list
(define (find-msgs type msgs)
  (filter (type=? type) msgs))

;; Shorthand for hash-ref with optional default
(define (msg-ref msg key [default #f])
  (hash-ref msg key default))

;; Find a cell:update message by cell name
(define (find-cell-update name msgs)
  (findf (lambda (m)
           (and ((type=? "cell:update") m)
                (equal? (msg-ref m 'name) name)))
         msgs))

;; Clean shutdown: close stdin → wait → kill if needed
(define (shutdown! proc to-racket)
  (with-handlers ([exn:fail? void])
    (close-output-port to-racket))
  (unless (sync/timeout 5 proc)
    (subprocess-kill proc #t)))


;; ═══════════════════════════════════════════════════════════════════════════
;; Test 1: Boot sequence — correct message types and ordering
;; ═══════════════════════════════════════════════════════════════════════════

(eprintf "\n=== E2E Protocol Tests ===\n\n")

(test-case "Test 1: Boot sequence"
  (eprintf "[test 1] Spawning main.rkt...\n")
  (define-values (proc from-racket to-racket) (spawn-main))
  (define boot-msgs
    (read-until from-racket (type=? "lifecycle:ready") 30))

  ;; Must end with lifecycle:ready
  (check-not-false (find-msg "lifecycle:ready" boot-msgs)
                   "Boot should end with lifecycle:ready")

  ;; 7 cell:register messages
  (define cell-regs (find-msgs "cell:register" boot-msgs))
  (check-equal? (length cell-regs) 7
                "Should have 7 cell:register messages")

  ;; All expected cells present
  (define cell-names
    (for/list ([m (in-list cell-regs)])
      (hash-ref m 'name)))
  (for ([expected '("current-file" "file-dirty" "title" "status"
                    "language" "cursor-pos" "project-root")])
    (check-not-false (member expected cell-names)
                     (format "Cell '~a' should be registered" expected)))

  ;; menu:set with 3 menus
  (define menu-msg (find-msg "menu:set" boot-msgs))
  (check-not-false menu-msg "Should have menu:set")
  (check-equal? (length (msg-ref menu-msg 'menu '())) 3
                "Menu should have 3 top-level items")

  ;; layout:set with layout hash
  (define layout-msg (find-msg "layout:set" boot-msgs))
  (check-not-false layout-msg "Should have layout:set")
  (check-true (hash? (msg-ref layout-msg 'layout))
              "layout:set should contain a layout hash")

  ;; pty:create for REPL
  (define pty-msg (find-msg "pty:create" boot-msgs))
  (check-not-false pty-msg "Should have pty:create")
  (check-equal? (msg-ref pty-msg 'id) "repl")
  (check-equal? (msg-ref pty-msg 'command) "racket")

  ;; cell:update for status = "REPL started"
  (define repl-status
    (findf (lambda (m)
             (and ((type=? "cell:update") m)
                  (equal? (msg-ref m 'name) "status")
                  (equal? (msg-ref m 'value) "REPL started")))
           boot-msgs))
  (check-not-false repl-status
                   "Should have cell:update status='REPL started'")

  ;; Ordering: cell:register < menu:set < layout:set < pty:create < lifecycle:ready
  (define (first-index type)
    (for/first ([m (in-list boot-msgs)]
                [i (in-naturals)]
                #:when ((type=? type) m))
      i))
  (define (last-index type)
    (for/fold ([idx 0])
              ([m (in-list boot-msgs)]
               [i (in-naturals)]
               #:when ((type=? type) m))
      i))

  (define last-reg-idx (last-index "cell:register"))
  (define menu-idx (first-index "menu:set"))
  (define layout-idx (first-index "layout:set"))
  (define pty-idx (first-index "pty:create"))
  (define ready-idx (first-index "lifecycle:ready"))

  (check-true (< last-reg-idx menu-idx)
              "All cell:register before menu:set")
  (check-true (< menu-idx layout-idx)
              "menu:set before layout:set")
  (check-true (< layout-idx pty-idx)
              "layout:set before pty:create")
  (check-true (< pty-idx ready-idx)
              "pty:create before lifecycle:ready")

  (eprintf "[test 1] Boot sequence OK (~a messages)\n" (length boot-msgs))
  (shutdown! proc to-racket))


;; ═══════════════════════════════════════════════════════════════════════════
;; Test 2: Ping/pong
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "Test 2: Ping/pong"
  (eprintf "[test 2] Spawning main.rkt...\n")
  (define-values (proc from-racket to-racket) (spawn-main))
  (read-until from-racket (type=? "lifecycle:ready") 30)

  (send-json! to-racket (hasheq 'type "ping"))
  (define response (read-json-msg from-racket 5))

  (check-not-false response "Should receive a response to ping")
  (check-equal? (hash-ref response 'type #f) "pong"
                "Response should be pong")

  (eprintf "[test 2] Ping/pong OK\n")
  (shutdown! proc to-racket))


;; ═══════════════════════════════════════════════════════════════════════════
;; Tests 3–6: File operations (shared subprocess)
;; ═══════════════════════════════════════════════════════════════════════════

(let ()
  (eprintf "[tests 3-6] Spawning main.rkt...\n")
  (define-values (proc from-racket to-racket) (spawn-main))
  (read-until from-racket (type=? "lifecycle:ready") 30)

  ;; ── Test 3: New file ──────────────────────────────────────────────────
  (test-case "Test 3: New file"
    (send-json! to-racket (hasheq 'type "event" 'name "new-file"))
    (define msgs (read-until from-racket (type=? "editor:open") 5))

    (define editor-msg (find-msg "editor:open" msgs))
    (check-not-false editor-msg "new-file should produce editor:open")
    (check-equal? (msg-ref editor-msg 'path) "untitled.rkt")
    (check-equal? (msg-ref editor-msg 'content) "#lang racket\n\n")
    (check-equal? (msg-ref editor-msg 'language) "racket")

    ;; Cell updates
    (check-not-false (find-cell-update "current-file" msgs))
    (check-equal? (msg-ref (find-cell-update "current-file" msgs) 'value)
                  "untitled.rkt")
    (check-not-false (find-cell-update "file-dirty" msgs))
    (check-equal? (msg-ref (find-cell-update "file-dirty" msgs) 'value) #f)
    (check-not-false (find-cell-update "language" msgs))
    (check-equal? (msg-ref (find-cell-update "language" msgs) 'value) "Racket")
    (check-not-false (find-cell-update "title" msgs))
    (check-not-false (find-cell-update "status" msgs))
    (check-equal? (msg-ref (find-cell-update "status" msgs) 'value) "New file")

    (eprintf "[test 3] New file OK\n"))

  ;; ── Test 4: File read result ──────────────────────────────────────────
  (test-case "Test 4: File read result"
    (send-json! to-racket
                (hasheq 'type "file:read:result"
                        'path "/tmp/test.rkt"
                        'content "#lang racket\n(define x 42)\n"))
    (define msgs (read-until from-racket (type=? "editor:open") 5))

    (define editor-msg (find-msg "editor:open" msgs))
    (check-not-false editor-msg "file:read:result should produce editor:open")
    (check-equal? (msg-ref editor-msg 'path) "/tmp/test.rkt")
    (check-equal? (msg-ref editor-msg 'language) "racket")
    (check-equal? (msg-ref editor-msg 'content) "#lang racket\n(define x 42)\n")

    (check-equal? (msg-ref (find-cell-update "current-file" msgs) 'value)
                  "/tmp/test.rkt")
    (check-equal? (msg-ref (find-cell-update "file-dirty" msgs) 'value) #f)
    (check-equal? (msg-ref (find-cell-update "language" msgs) 'value) "Racket")
    (check-true (string-contains?
                 (msg-ref (find-cell-update "title" msgs) 'value)
                 "test.rkt"))
    (check-true (string-contains?
                 (msg-ref (find-cell-update "status" msgs) 'value)
                 "test.rkt"))

    (eprintf "[test 4] File read result OK\n"))

  ;; ── Test 5: Dirty tracking ────────────────────────────────────────────
  (test-case "Test 5: Dirty tracking"
    ;; Reset with a new file first
    (send-json! to-racket (hasheq 'type "event" 'name "new-file"))
    (read-until from-racket (type=? "editor:open") 5)

    ;; Mark buffer dirty
    (send-json! to-racket (hasheq 'type "event" 'name "editor:dirty"))
    (define msgs
      (read-until from-racket
                  (lambda (m)
                    (and ((type=? "cell:update") m)
                         (equal? (msg-ref m 'name) "title")))
                  5))

    (define dirty-update (find-cell-update "file-dirty" msgs))
    (check-not-false dirty-update "Should get file-dirty update")
    (check-equal? (msg-ref dirty-update 'value) #t)

    (define title-update (find-cell-update "title" msgs))
    (check-not-false title-update "Should get title update")
    (check-true (string-contains? (msg-ref title-update 'value) "*")
                "Dirty title should contain *")

    (eprintf "[test 5] Dirty tracking OK\n"))

  ;; ── Test 6: #lang rhombus detection ───────────────────────────────────
  (test-case "Test 6: #lang rhombus detection"
    (send-json! to-racket
                (hasheq 'type "file:read:result"
                        'path "/tmp/demo.rhm"
                        'content "#lang rhombus\nfun f(): 1"))
    (define msgs (read-until from-racket (type=? "editor:open") 5))

    (define editor-msg (find-msg "editor:open" msgs))
    (check-not-false editor-msg)
    (check-equal? (msg-ref editor-msg 'language) "rhombus"
                  "Should detect rhombus language from #lang line")

    (define lang-update (find-cell-update "language" msgs))
    (check-not-false lang-update)
    (check-equal? (msg-ref lang-update 'value) "Rhombus"
                  "Language cell should show 'Rhombus'")

    (eprintf "[test 6] #lang rhombus detection OK\n"))

  (shutdown! proc to-racket))


;; ═══════════════════════════════════════════════════════════════════════════
;; Tests 7–10: Language intelligence (shared subprocess)
;; ═══════════════════════════════════════════════════════════════════════════

(let ()
  (eprintf "[tests 7-10] Spawning main.rkt...\n")
  (define-values (proc from-racket to-racket) (spawn-main))
  (read-until from-racket (type=? "lifecycle:ready") 30)

  ;; ── Test 7: Document opened → intel messages ──────────────────────────
  (test-case "Test 7: Document opened produces intel messages"
    (send-json! to-racket
                (hasheq 'type "event"
                        'name "document:opened"
                        'uri "/tmp/test.rkt"
                        'text "#lang racket\n(define x 42)\nx\n"))
    ;; intel:definitions is sent last by push-intel-to-frontend!
    (define msgs
      (read-until from-racket (type=? "intel:definitions") 60))

    ;; All 5 intel message types should be present
    (for ([type '("intel:diagnostics" "intel:arrows" "intel:hovers"
                  "intel:colors" "intel:definitions")])
      (check-not-false (find-msg type msgs)
                       (format "Should receive ~a" type)))

    ;; All should reference correct URI
    (for ([type '("intel:diagnostics" "intel:arrows" "intel:hovers"
                  "intel:colors" "intel:definitions")])
      (check-equal? (msg-ref (find-msg type msgs) 'uri) "/tmp/test.rkt"
                    (format "~a should reference correct URI" type)))

    ;; Should have at least one arrow (x references define binding)
    (define arrow-msg (find-msg "intel:arrows" msgs))
    (check-true (> (length (msg-ref arrow-msg 'arrows '())) 0)
                "Should have at least one arrow")

    ;; Should have hover entries
    (define hover-msg (find-msg "intel:hovers" msgs))
    (check-true (> (length (msg-ref hover-msg 'hovers '())) 0)
                "Should have at least one hover")

    (eprintf "[test 7] Document opened → intel OK\n"))

  ;; ── Test 8: Error diagnostics ─────────────────────────────────────────
  (test-case "Test 8: Error diagnostics"
    (send-json! to-racket
                (hasheq 'type "event"
                        'name "document:opened"
                        'uri "/tmp/err.rkt"
                        'text "#lang racket\n(define x)\n"))
    (define msgs
      (read-until from-racket (type=? "intel:definitions") 60))

    (define diag-msg (find-msg "intel:diagnostics" msgs))
    (check-not-false diag-msg "Should receive diagnostics")
    (define items (msg-ref diag-msg 'items '()))
    (check-true (> (length items) 0)
                "Should have at least one diagnostic item")
    (check-true (ormap (lambda (item)
                         (equal? (hash-ref item 'severity #f) "error"))
                       items)
                "Should have at least one error-severity diagnostic")

    (eprintf "[test 8] Error diagnostics OK\n"))

  ;; ── Test 9: Document changed → re-analysis ───────────────────────────
  (test-case "Test 9: Document changed triggers re-analysis"
    (send-json! to-racket
                (hasheq 'type "event"
                        'name "document:changed"
                        'uri "/tmp/test.rkt"
                        'text "#lang racket\n(define y 99)\ny\n"))
    (define msgs
      (read-until from-racket (type=? "intel:definitions") 60))

    ;; Fresh intel messages
    (check-not-false (find-msg "intel:diagnostics" msgs)
                     "Re-analysis should produce diagnostics")
    (check-not-false (find-msg "intel:arrows" msgs)
                     "Re-analysis should produce arrows")
    (check-not-false (find-msg "intel:definitions" msgs)
                     "Re-analysis should produce definitions")

    ;; Definitions should include 'y' from updated source
    (define def-msg (find-msg "intel:definitions" msgs))
    (define defs (msg-ref def-msg 'defs '()))
    (check-true (ormap (lambda (d) (equal? (hash-ref d 'name #f) "y"))
                       defs)
                "Definitions should include 'y' from updated source")

    (eprintf "[test 9] Document changed → re-analysis OK\n"))

  ;; ── Test 10: Completion request ───────────────────────────────────────
  (test-case "Test 10: Completion request"
    ;; Cache should have /tmp/test.rkt from Test 9 (with y defined)
    (send-json! to-racket
                (hasheq 'type "event"
                        'name "intel:completion-request"
                        'uri "/tmp/test.rkt"
                        'id 1
                        'prefix "y"))
    (define msgs
      (read-until from-racket (type=? "intel:completion-response") 5))

    (define comp-msg (find-msg "intel:completion-response" msgs))
    (check-not-false comp-msg "Should receive completion response")
    (check-equal? (msg-ref comp-msg 'id) 1
                  "Completion response should have matching id")
    (define items (msg-ref comp-msg 'items '()))
    (check-true (> (length items) 0)
                "Should have at least one completion item")
    (check-true (ormap (lambda (item)
                         (equal? (hash-ref item 'label #f) "y"))
                       items)
                "Completion items should include 'y'")

    (eprintf "[test 10] Completion request OK\n"))

  (shutdown! proc to-racket))


;; ═══════════════════════════════════════════════════════════════════════════
;; Tests 11–12: REPL and navigation (shared subprocess)
;; ═══════════════════════════════════════════════════════════════════════════

(let ()
  (eprintf "[tests 11-12] Spawning main.rkt...\n")
  (define-values (proc from-racket to-racket) (spawn-main))
  (read-until from-racket (type=? "lifecycle:ready") 30)

  ;; ── Test 11: Run command ──────────────────────────────────────────────
  (test-case "Test 11: Run command"
    ;; Open a file first so current-file is set
    (send-json! to-racket
                (hasheq 'type "file:read:result"
                        'path "/tmp/test.rkt"
                        'content "#lang racket\n(define x 42)\n"))
    (read-until from-racket (type=? "editor:open") 5)

    ;; Send run event
    (send-json! to-racket (hasheq 'type "event" 'name "run"))
    (define msgs
      (read-until from-racket
                  (lambda (m)
                    (and ((type=? "cell:update") m)
                         (equal? (msg-ref m 'name) "status")
                         (string-contains? (msg-ref m 'value "") "Running")))
                  5))

    (define pty-msg (find-msg "pty:write" msgs))
    (check-not-false pty-msg "Run should produce pty:write")
    (check-equal? (msg-ref pty-msg 'id) "repl")
    (check-true (string-contains? (msg-ref pty-msg 'data "") ",enter")
                "pty:write should contain ,enter command")
    (check-true (string-contains? (msg-ref pty-msg 'data "") "/tmp/test.rkt")
                "pty:write should contain the file path")

    (eprintf "[test 11] Run command OK\n"))

  ;; ── Test 12: Editor goto ──────────────────────────────────────────────
  (test-case "Test 12: Editor goto"
    (send-json! to-racket
                (hasheq 'type "event"
                        'name "editor:goto"
                        'line 5
                        'col 10))
    (define msgs
      (read-until from-racket (type=? "editor:goto") 5))

    (define goto-msg (find-msg "editor:goto" msgs))
    (check-not-false goto-msg "editor:goto event should produce editor:goto message")
    (check-equal? (msg-ref goto-msg 'line) 5)
    (check-equal? (msg-ref goto-msg 'col) 10)

    (eprintf "[test 12] Editor goto OK\n"))

  (shutdown! proc to-racket))


(eprintf "\n=== All E2E protocol tests complete ===\n")
