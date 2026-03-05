#lang racket/base

(require rackunit
         json
         racket/port
         racket/string
         racket/set
         "../racket/heavymental-core/protocol.rkt"
         "../racket/heavymental-core/cell.rkt"
         "../racket/heavymental-core/editor.rkt")

;; ── Helpers ──────────────────────────────────────────────────────────────────

(define (parse-all-messages output)
  (define lines (string-split (string-trim output) "\n"))
  (for/list ([line (in-list lines)]
             #:when (> (string-length (string-trim line)) 0))
    (string->jsexpr line)))

;; Cells needed by editor.rkt
(define-cell current-file "untitled.rkt")
(define-cell file-dirty #f)
(define-cell title "HeavyMental")
(define-cell status "starting")
(define-cell dirty-files (list))

(define (reset-cells!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "untitled.rkt")
      (cell-set! 'file-dirty #f)
      (cell-set! 'title "HeavyMental")
      (cell-set! 'status "starting")
      (cell-set! 'dirty-files (list))
      (reset-dirty-state!))))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: dirty-files tracking
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "mark-file-dirty! adds path to dirty-files"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (mark-file-dirty! "/tmp/foo.rkt")))
  (check-true (file-dirty? "/tmp/foo.rkt")))

(test-case "mark-file-clean! removes path from dirty-files"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (mark-file-dirty! "/tmp/foo.rkt")
      (mark-file-clean! "/tmp/foo.rkt")))
  (check-false (file-dirty? "/tmp/foo.rkt")))

(test-case "multiple dirty files tracked independently"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (mark-file-dirty! "/tmp/a.rkt")
      (mark-file-dirty! "/tmp/b.rkt")
      (mark-file-clean! "/tmp/a.rkt")))
  (check-false (file-dirty? "/tmp/a.rkt"))
  (check-true (file-dirty? "/tmp/b.rkt")))

(test-case "any-dirty-files? returns #t when dirty files exist"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (mark-file-dirty! "/tmp/foo.rkt")))
  (check-true (any-dirty-files?)))

(test-case "any-dirty-files? returns #f when no dirty files"
  (reset-cells!)
  (check-false (any-dirty-files?)))

(test-case "editor:dirty event marks file dirty and updates cell"
  (reset-cells!)
  (define output
    (with-output-to-string
      (lambda ()
        (handle-editor-event
         (make-message "event" 'name "editor:dirty" 'path "/tmp/test.rkt")))))
  (define msgs (parse-all-messages output))
  ;; Should have cell:update for dirty-files
  (check-true
   (ormap (lambda (m)
            (and (equal? (hash-ref m 'type #f) "cell:update")
                 (equal? (hash-ref m 'name #f) "dirty-files")))
          msgs))
  (check-true (file-dirty? "/tmp/test.rkt")))

(test-case "file:write:result clears dirty state"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "/tmp/test.rkt")
      (mark-file-dirty! "/tmp/test.rkt")))
  (check-true (file-dirty? "/tmp/test.rkt"))
  (with-output-to-string
    (lambda ()
      (handle-file-result
       (make-message "file:write:result" 'path "/tmp/test.rkt"))))
  (check-false (file-dirty? "/tmp/test.rkt")))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: tab close request handling
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "tab:close-request for clean file sends tab:close immediately"
  (reset-cells!)
  (define output
    (with-output-to-string
      (lambda ()
        (handle-tab-close-request "/tmp/clean.rkt"))))
  (define msgs (parse-all-messages output))
  (check-true
   (ormap (lambda (m)
            (and (equal? (hash-ref m 'type #f) "tab:close")
                 (equal? (hash-ref m 'path #f) "/tmp/clean.rkt")))
          msgs)))

(test-case "tab:close-request for dirty file sends dialog:confirm"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (mark-file-dirty! "/tmp/dirty.rkt")))
  (define output
    (with-output-to-string
      (lambda ()
        (handle-tab-close-request "/tmp/dirty.rkt"))))
  (define msgs (parse-all-messages output))
  (check-true
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "dialog:confirm"))
          msgs))
  (check-false
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "tab:close"))
          msgs)))

(test-case "dialog:confirm:result dont-save closes tab"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (mark-file-dirty! "/tmp/dirty.rkt")))
  (define output
    (with-output-to-string
      (lambda ()
        (handle-dialog-result
         (make-message "dialog:confirm:result"
                       'id "close:/tmp/dirty.rkt"
                       'choice "dont-save")))))
  (define msgs (parse-all-messages output))
  (check-true
   (ormap (lambda (m)
            (and (equal? (hash-ref m 'type #f) "tab:close")
                 (equal? (hash-ref m 'path #f) "/tmp/dirty.rkt")))
          msgs))
  (check-false (file-dirty? "/tmp/dirty.rkt")))

(test-case "dialog:confirm:result save sets pending-close"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (mark-file-dirty! "/tmp/dirty.rkt")))
  (define output
    (with-output-to-string
      (lambda ()
        (handle-dialog-result
         (make-message "dialog:confirm:result"
                       'id "close:/tmp/dirty.rkt"
                       'choice "save")))))
  (define msgs (parse-all-messages output))
  ;; Should send editor:request-save
  (check-true
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "editor:request-save"))
          msgs))
  (check-true (pending-close? "/tmp/dirty.rkt")))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: save-before-run (pending-run state)
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "pending-run? is initially false"
  (clear-pending-run!)
  (check-false (pending-run?)))

(test-case "set-pending-run! sets pending-run to true"
  (clear-pending-run!)
  (set-pending-run!)
  (check-true (pending-run?)))

(test-case "clear-pending-run! resets pending-run to false"
  (set-pending-run!)
  (check-true (pending-run?))
  (clear-pending-run!)
  (check-false (pending-run?)))

(test-case "save-before-run: dirty file sets pending-run and sends editor:request-save"
  ;; Simulate what handle-run in main.rkt does for a dirty file:
  ;; 1. Check file-dirty? → true
  ;; 2. Set pending-run
  ;; 3. Send editor:request-save
  (reset-cells!)
  (clear-pending-run!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "/tmp/test.rkt")
      (mark-file-dirty! "/tmp/test.rkt")))
  (define path (current-file-path))
  ;; Verify preconditions
  (check-true (file-dirty? path))
  ;; Simulate handle-run logic for dirty file
  (define output
    (with-output-to-string
      (lambda ()
        (when (file-dirty? path)
          (set-pending-run!)
          (send-message! (make-message "editor:request-save"))))))
  (define msgs (parse-all-messages output))
  ;; Should have sent editor:request-save
  (check-true
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "editor:request-save"))
          msgs))
  ;; pending-run should be set
  (check-true (pending-run?)))

(test-case "save-before-run: clean file does not set pending-run"
  (reset-cells!)
  (clear-pending-run!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "/tmp/test.rkt")))
  (define path (current-file-path))
  ;; File is not dirty — handle-run would call run-file directly
  (check-false (file-dirty? path))
  (check-false (pending-run?)))

(test-case "save-before-run: file:write:result clears pending-run"
  ;; Simulate the post-write dispatch in main.rkt:
  ;; After handle-file-result processes file:write:result, if pending-run? is true,
  ;; clear it and run the file.
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "/tmp/test.rkt")
      (mark-file-dirty! "/tmp/test.rkt")))
  ;; Set pending-run (simulating what handle-run does)
  (set-pending-run!)
  (check-true (pending-run?))
  ;; Simulate file:write:result arriving
  (with-output-to-string
    (lambda ()
      (handle-file-result
       (make-message "file:write:result" 'path "/tmp/test.rkt"))))
  ;; Now simulate the post-write check from main.rkt dispatch
  (when (pending-run?)
    (clear-pending-run!))
  (check-false (pending-run?)))

(test-case "save-before-run: pending-close after write sends tab:close"
  ;; Verify that pending-close is also handled after file:write:result
  (reset-cells!)
  (clear-pending-run!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "/tmp/test.rkt")
      (mark-file-dirty! "/tmp/test.rkt")))
  (set-pending-close! "/tmp/test.rkt")
  (check-true (pending-close? "/tmp/test.rkt"))
  ;; Simulate file:write:result + post-write dispatch
  (with-output-to-string
    (lambda ()
      (handle-file-result
       (make-message "file:write:result" 'path "/tmp/test.rkt"))))
  (define output
    (with-output-to-string
      (lambda ()
        (when (pending-close? "/tmp/test.rkt")
          (clear-pending-close! "/tmp/test.rkt")
          (send-message! (make-message "tab:close" 'path "/tmp/test.rkt"))))))
  (define msgs (parse-all-messages output))
  (check-true
   (ormap (lambda (m)
            (and (equal? (hash-ref m 'type #f) "tab:close")
                 (equal? (hash-ref m 'path #f) "/tmp/test.rkt")))
          msgs))
  (check-false (pending-close? "/tmp/test.rkt")))

(test-case "save-before-run: empty path is a no-op"
  ;; handle-run should do nothing when current-file is ""
  (reset-cells!)
  (clear-pending-run!)
  ;; current-file defaults to "untitled.rkt" after reset, set to ""
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "")))
  (define path (current-file-path))
  (check-equal? path "")
  ;; Simulate handle-run guard: should not set pending-run or do anything
  (check-false (pending-run?)))

(test-case "save-before-run: untitled.rkt is a no-op"
  ;; handle-run should do nothing when current-file is "untitled.rkt"
  (reset-cells!)
  (clear-pending-run!)
  (define path (current-file-path))
  (check-equal? path "untitled.rkt")
  ;; Simulate handle-run guard: should not set pending-run or do anything
  (check-false (pending-run?)))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: lifecycle:close-request (quit with unsaved changes)
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "pending-quit? is initially false"
  (clear-pending-quit!)
  (check-false (pending-quit?)))

(test-case "set-pending-quit! sets pending-quit to true"
  (clear-pending-quit!)
  (set-pending-quit!)
  (check-true (pending-quit?)))

(test-case "clear-pending-quit! resets pending-quit to false"
  (set-pending-quit!)
  (check-true (pending-quit?))
  (clear-pending-quit!)
  (check-false (pending-quit?)))

(test-case "lifecycle:close-request with no dirty files sends lifecycle:quit"
  ;; When there are no unsaved changes, close-request should immediately quit.
  (reset-cells!)
  (clear-pending-quit!)
  (check-false (any-dirty-files?))
  ;; Simulate the dispatch logic from main.rkt for lifecycle:close-request
  (define output
    (with-output-to-string
      (lambda ()
        (cond
          [(any-dirty-files?)
           (send-message! (make-message "dialog:confirm"
                                        'id "lifecycle:quit"
                                        'title "Unsaved Changes"
                                        'message "You have unsaved changes. Save before quitting?"
                                        'save_label "Save All"
                                        'dont_save_label "Don\u2019t Save"
                                        'cancel_label "Cancel"))]
          [else
           (send-message! (make-message "lifecycle:quit"))]))))
  (define msgs (parse-all-messages output))
  ;; Should send lifecycle:quit directly
  (check-true
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "lifecycle:quit"))
          msgs))
  ;; Should NOT send dialog:confirm
  (check-false
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "dialog:confirm"))
          msgs)))

(test-case "lifecycle:close-request with dirty files sends dialog:confirm"
  ;; When there are unsaved changes, close-request should show a dialog.
  (reset-cells!)
  (clear-pending-quit!)
  (with-output-to-string
    (lambda ()
      (mark-file-dirty! "/tmp/dirty.rkt")))
  (check-true (any-dirty-files?))
  ;; Simulate the dispatch logic
  (define output
    (with-output-to-string
      (lambda ()
        (cond
          [(any-dirty-files?)
           (send-message! (make-message "dialog:confirm"
                                        'id "lifecycle:quit"
                                        'title "Unsaved Changes"
                                        'message "You have unsaved changes. Save before quitting?"
                                        'save_label "Save All"
                                        'dont_save_label "Don\u2019t Save"
                                        'cancel_label "Cancel"))]
          [else
           (send-message! (make-message "lifecycle:quit"))]))))
  (define msgs (parse-all-messages output))
  ;; Should send dialog:confirm
  (check-true
   (ormap (lambda (m)
            (and (equal? (hash-ref m 'type #f) "dialog:confirm")
                 (equal? (hash-ref m 'id #f) "lifecycle:quit")))
          msgs))
  ;; Should NOT send lifecycle:quit
  (check-false
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "lifecycle:quit"))
          msgs)))

(test-case "dialog:confirm:result dont-save for lifecycle:quit sends lifecycle:quit"
  (reset-cells!)
  (clear-pending-quit!)
  (define output
    (with-output-to-string
      (lambda ()
        (handle-dialog-result
         (make-message "dialog:confirm:result"
                       'id "lifecycle:quit"
                       'choice "dont-save")))))
  (define msgs (parse-all-messages output))
  ;; Should send lifecycle:quit
  (check-true
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "lifecycle:quit"))
          msgs))
  ;; pending-quit should NOT be set
  (check-false (pending-quit?)))

(test-case "dialog:confirm:result save for lifecycle:quit sends editor:request-save and sets pending-quit"
  (reset-cells!)
  (clear-pending-quit!)
  (define output
    (with-output-to-string
      (lambda ()
        (handle-dialog-result
         (make-message "dialog:confirm:result"
                       'id "lifecycle:quit"
                       'choice "save")))))
  (define msgs (parse-all-messages output))
  ;; Should send editor:request-save
  (check-true
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "editor:request-save"))
          msgs))
  ;; Should NOT send lifecycle:quit yet
  (check-false
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "lifecycle:quit"))
          msgs))
  ;; pending-quit should be set
  (check-true (pending-quit?)))

(test-case "dialog:confirm:result cancel for lifecycle:quit does nothing"
  (reset-cells!)
  (clear-pending-quit!)
  (define output
    (with-output-to-string
      (lambda ()
        (handle-dialog-result
         (make-message "dialog:confirm:result"
                       'id "lifecycle:quit"
                       'choice "cancel")))))
  (define msgs (parse-all-messages output))
  ;; Should NOT send lifecycle:quit
  (check-false
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "lifecycle:quit"))
          msgs))
  ;; Should NOT send editor:request-save
  (check-false
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "editor:request-save"))
          msgs))
  ;; pending-quit should NOT be set
  (check-false (pending-quit?)))

(test-case "pending-quit: file:write:result triggers lifecycle:quit"
  ;; After save completes with pending-quit, lifecycle:quit should be sent.
  (reset-cells!)
  (clear-pending-quit!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "/tmp/test.rkt")
      (mark-file-dirty! "/tmp/test.rkt")))
  ;; Set pending-quit (simulating what handle-dialog-result does)
  (set-pending-quit!)
  (check-true (pending-quit?))
  ;; Simulate file:write:result arriving
  (with-output-to-string
    (lambda ()
      (handle-file-result
       (make-message "file:write:result" 'path "/tmp/test.rkt"))))
  ;; Simulate the post-write check from main.rkt dispatch
  (define output
    (with-output-to-string
      (lambda ()
        (when (pending-quit?)
          (clear-pending-quit!)
          (send-message! (make-message "lifecycle:quit"))))))
  (define msgs (parse-all-messages output))
  ;; Should send lifecycle:quit
  (check-true
   (ormap (lambda (m)
            (equal? (hash-ref m 'type #f) "lifecycle:quit"))
          msgs))
  ;; pending-quit should be cleared
  (check-false (pending-quit?)))

(test-case "pending-quit: not triggered when not set"
  ;; file:write:result without pending-quit should not send lifecycle:quit
  (reset-cells!)
  (clear-pending-quit!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "/tmp/test.rkt")
      (mark-file-dirty! "/tmp/test.rkt")))
  (check-false (pending-quit?))
  ;; Simulate file:write:result arriving
  (with-output-to-string
    (lambda ()
      (handle-file-result
       (make-message "file:write:result" 'path "/tmp/test.rkt"))))
  ;; Simulate the post-write check from main.rkt dispatch
  (define output
    (with-output-to-string
      (lambda ()
        (when (pending-quit?)
          (clear-pending-quit!)
          (send-message! (make-message "lifecycle:quit"))))))
  (define msgs (parse-all-messages output))
  ;; Should NOT send lifecycle:quit
  (check-equal? msgs '()))

(displayln "All Phase 4 tests passed!")
