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

(displayln "All Phase 4 tests passed!")
