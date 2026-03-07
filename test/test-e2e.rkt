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

  ;; 12 cell:register messages (7 original + 5 Phase 4: dirty-files, repl-running, stepper-active, stepper-step, stepper-total)
  (define cell-regs (find-msgs "cell:register" boot-msgs))
  (check-equal? (length cell-regs) 12
                "Should have 12 cell:register messages")

  ;; All expected cells present
  (define cell-names
    (for/list ([m (in-list cell-regs)])
      (hash-ref m 'name)))
  (for ([expected '("current-file" "file-dirty" "title" "status"
                    "language" "cursor-pos" "project-root"
                    "dirty-files" "repl-running"
                    "stepper-active" "stepper-step" "stepper-total")])
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

    ;; Phase 4 sends two pty:write messages:
    ;;   1. clear-repl (\x0c form feed)
    ;;   2. ,enter "path" (the actual run command)
    (define pty-msgs (find-msgs "pty:write" msgs))
    (check-true (>= (length pty-msgs) 2)
                "Run should produce at least 2 pty:write messages (clear + enter)")

    ;; First pty:write is the REPL clear
    (define clear-msg (first pty-msgs))
    (check-equal? (msg-ref clear-msg 'id) "repl")
    (check-equal? (msg-ref clear-msg 'data) "\f"
                  "First pty:write should be form-feed (clear)")

    ;; Second pty:write is the ,enter command
    (define enter-msg (second pty-msgs))
    (check-equal? (msg-ref enter-msg 'id) "repl")
    (check-true (string-contains? (msg-ref enter-msg 'data "") ",enter")
                "Second pty:write should contain ,enter command")
    (check-true (string-contains? (msg-ref enter-msg 'data "") "/tmp/test.rkt")
                "Second pty:write should contain the file path")

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


;; ═══════════════════════════════════════════════════════════════════════════
;; Tests 13–19: Phase 4 features (shared subprocess)
;; ═══════════════════════════════════════════════════════════════════════════

(let ()
  (eprintf "[tests 13-19] Spawning main.rkt...\n")
  (define-values (proc from-racket to-racket) (spawn-main))
  (read-until from-racket (type=? "lifecycle:ready") 30)

  ;; ── Test 13: dirty-files cell tracks multiple dirty files ──────────
  (test-case "Test 13: dirty-files cell tracks multiple files"
    ;; Open a file and mark it dirty
    (send-json! to-racket
                (hasheq 'type "file:read:result"
                        'path "/tmp/a.rkt"
                        'content "#lang racket\n"))
    (read-until from-racket (type=? "editor:open") 5)

    ;; editor:dirty produces: dirty-files update, file-dirty update, title update
    ;; Drain through the title update to avoid leftover messages
    (send-json! to-racket
                (hasheq 'type "event" 'name "editor:dirty"
                        'path "/tmp/a.rkt"))
    (define msgs-a
      (read-until from-racket
                  (lambda (m) (and ((type=? "cell:update") m)
                                   (equal? (msg-ref m 'name) "title")))
                  5))

    (define dirty-update-a (find-cell-update "dirty-files" msgs-a))
    (check-not-false dirty-update-a
                     "dirty-files cell should update when file marked dirty")
    (check-not-false (member "/tmp/a.rkt" (msg-ref dirty-update-a 'value '()))
                     "dirty-files should contain /tmp/a.rkt")

    ;; Open a second file and mark it dirty too
    (send-json! to-racket
                (hasheq 'type "file:read:result"
                        'path "/tmp/b.rkt"
                        'content "#lang racket\n"))
    (read-until from-racket (type=? "editor:open") 5)

    ;; Drain through the title update
    (send-json! to-racket
                (hasheq 'type "event" 'name "editor:dirty"
                        'path "/tmp/b.rkt"))
    (define msgs-b
      (read-until from-racket
                  (lambda (m) (and ((type=? "cell:update") m)
                                   (equal? (msg-ref m 'name) "title")))
                  5))

    (define dirty-update-b (find-cell-update "dirty-files" msgs-b))
    (check-not-false dirty-update-b)
    (define dirty-paths (msg-ref dirty-update-b 'value '()))
    (check-not-false (member "/tmp/b.rkt" dirty-paths)
                     "dirty-files should contain /tmp/b.rkt")

    (eprintf "[test 13] dirty-files cell tracking OK\n"))

  ;; ── Test 14: file:write:result clears dirty state ─────────────────
  (test-case "Test 14: file:write:result clears dirty state"
    ;; File /tmp/b.rkt is dirty from test 13. Save it.
    ;; file:write:result produces: current-file, file-dirty, dirty-files, title, status
    ;; Drain through status to avoid leftover messages
    (send-json! to-racket
                (hasheq 'type "file:write:result"
                        'path "/tmp/b.rkt"))
    (define msgs
      (read-until from-racket
                  (lambda (m) (and ((type=? "cell:update") m)
                                   (equal? (msg-ref m 'name) "status")
                                   (string-contains? (msg-ref m 'value "") "Saved")))
                  5))

    (define dirty-update (find-cell-update "dirty-files" msgs))
    (check-not-false dirty-update
                     "dirty-files should update after save")
    ;; /tmp/b.rkt should no longer be in the dirty list
    (check-false (member "/tmp/b.rkt" (msg-ref dirty-update 'value '()))
                 "/tmp/b.rkt should be removed from dirty-files after save")

    ;; file-dirty should be #f
    (define dirty-bool (find-cell-update "file-dirty" msgs))
    (check-not-false dirty-bool)
    (check-equal? (msg-ref dirty-bool 'value) #f
                  "file-dirty should be #f after save")

    (eprintf "[test 14] file:write:result clears dirty OK\n"))

  ;; ── Test 15: save-before-run (dirty file triggers deferred run) ───
  (test-case "Test 15: save-before-run defers run until save completes"
    ;; Open and dirty a file
    (send-json! to-racket
                (hasheq 'type "file:read:result"
                        'path "/tmp/run-test.rkt"
                        'content "#lang racket\n(+ 1 2)\n"))
    (read-until from-racket (type=? "editor:open") 5)

    (send-json! to-racket
                (hasheq 'type "event" 'name "editor:dirty"
                        'path "/tmp/run-test.rkt"))
    (read-until from-racket
                (lambda (m) (and ((type=? "cell:update") m)
                                 (equal? (msg-ref m 'name) "dirty-files")))
                5)

    ;; Run while file is dirty — should NOT produce pty:write yet
    ;; Instead should produce editor:request-save
    (send-json! to-racket (hasheq 'type "event" 'name "run"))
    (define msgs-run
      (read-until from-racket (type=? "editor:request-save") 5))

    (define save-req (find-msg "editor:request-save" msgs-run))
    (check-not-false save-req
                     "Run on dirty file should trigger editor:request-save")

    ;; No pty:write yet (the run is deferred)
    (check-false (find-msg "pty:write" msgs-run)
                 "Deferred run should NOT produce pty:write before save")

    ;; Now simulate the save completing
    (send-json! to-racket
                (hasheq 'type "file:write:result"
                        'path "/tmp/run-test.rkt"))
    (define msgs-post-save
      (read-until from-racket
                  (lambda (m) (and ((type=? "cell:update") m)
                                   (equal? (msg-ref m 'name) "status")
                                   (string-contains? (msg-ref m 'value "") "Running")))
                  5))

    ;; Now pty:write should appear (clear + enter)
    (define pty-msgs (find-msgs "pty:write" msgs-post-save))
    (check-true (>= (length pty-msgs) 2)
                "Deferred run should produce pty:write after save")

    ;; repl-running should be #t
    (define repl-update (find-cell-update "repl-running" msgs-post-save))
    (check-not-false repl-update)
    (check-equal? (msg-ref repl-update 'value) #t
                  "repl-running should be #t after run")

    (eprintf "[test 15] save-before-run OK\n"))

  ;; ── Test 16: tab:close-request for clean file closes immediately ──
  (test-case "Test 16: tab close clean file sends tab:close"
    ;; Open a clean file
    (send-json! to-racket
                (hasheq 'type "file:read:result"
                        'path "/tmp/clean.rkt"
                        'content "#lang racket\n"))
    (read-until from-racket (type=? "editor:open") 5)

    ;; Close request on a clean file — should close immediately
    (send-json! to-racket
                (hasheq 'type "event" 'name "tab:close-request"
                        'path "/tmp/clean.rkt"))
    (define msgs
      (read-until from-racket (type=? "tab:close") 5))

    (define close-msg (find-msg "tab:close" msgs))
    (check-not-false close-msg
                     "Clean file tab:close-request should produce tab:close")
    (check-equal? (msg-ref close-msg 'path) "/tmp/clean.rkt")

    (eprintf "[test 16] tab close clean file OK\n"))

  ;; ── Test 17: tab:close-request for dirty file shows dialog ────────
  (test-case "Test 17: tab close dirty file shows dialog"
    ;; Open and dirty a file
    (send-json! to-racket
                (hasheq 'type "file:read:result"
                        'path "/tmp/dirty-close.rkt"
                        'content "#lang racket\n"))
    (read-until from-racket (type=? "editor:open") 5)

    (send-json! to-racket
                (hasheq 'type "event" 'name "editor:dirty"
                        'path "/tmp/dirty-close.rkt"))
    (read-until from-racket
                (lambda (m) (and ((type=? "cell:update") m)
                                 (equal? (msg-ref m 'name) "dirty-files")))
                5)

    ;; Close request on dirty file — should show dialog
    (send-json! to-racket
                (hasheq 'type "event" 'name "tab:close-request"
                        'path "/tmp/dirty-close.rkt"))
    (define msgs
      (read-until from-racket (type=? "dialog:confirm") 5))

    (define dialog-msg (find-msg "dialog:confirm" msgs))
    (check-not-false dialog-msg
                     "Dirty file tab:close-request should show dialog")
    (check-true (string-contains? (msg-ref dialog-msg 'id "") "close:")
                "Dialog id should start with 'close:'")

    ;; Simulate "Don't Save" response
    (send-json! to-racket
                (hasheq 'type "dialog:confirm:result"
                        'id (msg-ref dialog-msg 'id)
                        'choice "dont-save"))
    (define close-msgs
      (read-until from-racket (type=? "tab:close") 5))

    (define close-msg (find-msg "tab:close" close-msgs))
    (check-not-false close-msg
                     "Don't Save should produce tab:close")
    (check-equal? (msg-ref close-msg 'path) "/tmp/dirty-close.rkt")

    (eprintf "[test 17] tab close dirty file OK\n"))

  ;; ── Test 18: lifecycle:close-request with dirty files ──────────────
  (test-case "Test 18: lifecycle close with dirty files shows dialog"
    ;; Open and dirty a file
    (send-json! to-racket
                (hasheq 'type "file:read:result"
                        'path "/tmp/quit-test.rkt"
                        'content "#lang racket\n"))
    (read-until from-racket (type=? "editor:open") 5)

    (send-json! to-racket
                (hasheq 'type "event" 'name "editor:dirty"
                        'path "/tmp/quit-test.rkt"))
    (read-until from-racket
                (lambda (m) (and ((type=? "cell:update") m)
                                 (equal? (msg-ref m 'name) "dirty-files")))
                5)

    ;; Window close request — should show dialog
    (send-json! to-racket
                (hasheq 'type "lifecycle:close-request"))
    (define msgs
      (read-until from-racket (type=? "dialog:confirm") 5))

    (define dialog-msg (find-msg "dialog:confirm" msgs))
    (check-not-false dialog-msg
                     "lifecycle:close-request with dirty files should show dialog")
    (check-equal? (msg-ref dialog-msg 'id) "lifecycle:quit"
                  "Dialog id should be 'lifecycle:quit'")

    ;; Simulate "Don't Save" response — should quit immediately
    (send-json! to-racket
                (hasheq 'type "dialog:confirm:result"
                        'id "lifecycle:quit"
                        'choice "dont-save"))
    (define quit-msgs
      (read-until from-racket (type=? "lifecycle:quit") 5))

    (define quit-msg (find-msg "lifecycle:quit" quit-msgs))
    (check-not-false quit-msg
                     "Don't Save should produce lifecycle:quit")

    (eprintf "[test 18] lifecycle close with dirty files OK\n"))

  ;; ── Test 19: REPL restart ─────────────────────────────────────────
  (test-case "Test 19: REPL restart"
    (send-json! to-racket
                (hasheq 'type "event" 'name "repl:restart"))
    (define msgs
      (read-until from-racket
                  (lambda (m)
                    (and ((type=? "cell:update") m)
                         (equal? (msg-ref m 'name) "status")
                         (equal? (msg-ref m 'value) "REPL started")))
                  5))

    ;; Should produce pty:kill followed by pty:create
    (define kill-msg (find-msg "pty:kill" msgs))
    (check-not-false kill-msg "Restart should produce pty:kill")
    (check-equal? (msg-ref kill-msg 'id) "repl")

    (define create-msg (find-msg "pty:create" msgs))
    (check-not-false create-msg "Restart should produce pty:create")
    (check-equal? (msg-ref create-msg 'id) "repl")
    (check-equal? (msg-ref create-msg 'command) "racket")

    ;; repl-running should have been set to #f before restart
    (define repl-off
      (findf (lambda (m)
               (and ((type=? "cell:update") m)
                    (equal? (msg-ref m 'name) "repl-running")
                    (equal? (msg-ref m 'value) #f)))
             msgs))
    (check-not-false repl-off
                     "repl-running should be set to #f during restart")

    (eprintf "[test 19] REPL restart OK\n"))

  (shutdown! proc to-racket))


;; ═══════════════════════════════════════════════════════════════════════════
;; Tests 20–22: Stepper (separate subprocess — needs filesystem)
;; ═══════════════════════════════════════════════════════════════════════════

(let ()
  (eprintf "[tests 20-22] Spawning main.rkt...\n")
  (define-values (proc from-racket to-racket) (spawn-main))
  (read-until from-racket (type=? "lifecycle:ready") 30)

  ;; Create a simple test file for the stepper
  (define stepper-file "/tmp/heavymental-stepper-test.rkt")
  (call-with-output-file stepper-file
    (lambda (out) (display "#lang racket\n(define x (+ 1 2))\nx\n" out))
    #:exists 'replace)

  ;; ── Test 20: Stepper start ─────────────────────────────────────────
  (test-case "Test 20: Stepper start produces step and activates cells"
    (send-json! to-racket
                (hasheq 'type "event" 'name "stepper:start"
                        'path stepper-file))

    ;; Wait for the first stepper:step message
    (define msgs
      (read-until from-racket (type=? "stepper:step") 30))

    ;; stepper-active should be #t
    (define active-update (find-cell-update "stepper-active" msgs))
    (check-not-false active-update
                     "stepper-active cell should be updated")
    (check-equal? (msg-ref active-update 'value) #t
                  "stepper-active should be #t after start")

    ;; First step message should arrive
    (define step-msg (find-msg "stepper:step" msgs))
    (check-not-false step-msg "Should receive stepper:step")
    (check-equal? (msg-ref step-msg 'step) 1
                  "First step should be step 1")

    ;; Step data should be a hash with 'type
    (define data (msg-ref step-msg 'data))
    (check-true (hash? data) "Step data should be a hash")
    (check-true (hash-has-key? data 'type)
                "Step data should have a 'type field")

    (eprintf "[test 20] Stepper start OK\n"))

  ;; ── Test 21: Stepper forward navigates to next step ────────────────
  (test-case "Test 21: Stepper forward produces next step"
    (send-json! to-racket
                (hasheq 'type "event" 'name "stepper:forward"))

    ;; Wait for the next stepper:step message
    (define msgs
      (read-until from-racket (type=? "stepper:step") 30))

    (define step-msg (find-msg "stepper:step" msgs))
    (check-not-false step-msg "Should receive stepper:step after forward")
    ;; Step number should be >= 2
    (check-true (>= (msg-ref step-msg 'step 0) 2)
                "Step number should be >= 2 after forward")

    ;; stepper-step cell should be updated
    (define step-update (find-cell-update "stepper-step" msgs))
    (check-not-false step-update
                     "stepper-step cell should update on forward")

    (eprintf "[test 21] Stepper forward OK\n"))

  ;; ── Test 22: Stepper stop cleans up ─────────────────────────────────
  (test-case "Test 22: Stepper stop deactivates"
    (send-json! to-racket
                (hasheq 'type "event" 'name "stepper:stop"))

    (define msgs
      (read-until from-racket (type=? "stepper:finished") 10))

    (define finished-msg (find-msg "stepper:finished" msgs))
    (check-not-false finished-msg "Should receive stepper:finished on stop")
    (check-true (>= (msg-ref finished-msg 'total 0) 0)
                "Total should be >= 0")

    ;; stepper-active should be #f
    (define active-update (find-cell-update "stepper-active" msgs))
    (check-not-false active-update
                     "stepper-active cell should update on stop")
    (check-equal? (msg-ref active-update 'value) #f
                  "stepper-active should be #f after stop")

    (eprintf "[test 22] Stepper stop OK\n"))

  ;; Clean up stepper test file
  (with-handlers ([exn:fail? void])
    (delete-file stepper-file))

  (shutdown! proc to-racket))


(eprintf "\n=== All E2E protocol tests complete ===\n")
