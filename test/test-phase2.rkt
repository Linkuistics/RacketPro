#lang racket/base

(require rackunit
         json
         racket/port
         racket/string
         "../racket/mrracket-core/protocol.rkt"
         "../racket/mrracket-core/cell.rkt"
         "../racket/mrracket-core/editor.rkt"
         "../racket/mrracket-core/repl.rkt")

;; ── Helpers ──────────────────────────────────────────────────────────────────

;; Parse all JSON messages from a captured output string.
;; Each message is one newline-terminated JSON object.
(define (parse-all-messages output)
  (define lines (string-split (string-trim output) "\n"))
  (for/list ([line (in-list lines)]
             #:when (> (string-length (string-trim line)) 0))
    (string->jsexpr line)))

;; Reset cells to a known state before each handler test.
;; These cells are normally defined in main.rkt.
(define (reset-cells!)
  ;; Use with-output-to-string to suppress cell:update messages
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "untitled.rkt")
      (cell-set! 'file-dirty #f)
      (cell-set! 'title "MrRacket")
      (cell-set! 'status "starting"))))

;; ── Ensure cells exist ──────────────────────────────────────────────────────
;; define-cell must be called once at top level (macro expands to make-cell)
(define-cell current-file "untitled.rkt")
(define-cell file-dirty #f)
(define-cell title "MrRacket")
(define-cell status "starting")

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: path->filename
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "path->filename extracts filename from Unix path"
  (check-equal? (path->filename "/home/user/projects/demo.rkt") "demo.rkt"))

(test-case "path->filename extracts filename from Windows path"
  (check-equal? (path->filename "C:\\Users\\user\\demo.rkt") "demo.rkt"))

(test-case "path->filename returns bare filename unchanged"
  (check-equal? (path->filename "untitled.rkt") "untitled.rkt"))

(test-case "path->filename handles path with mixed separators"
  (check-equal? (path->filename "/home/user\\mixed/file.txt") "file.txt"))

(test-case "path->filename handles deeply nested path"
  (check-equal? (path->filename "/a/b/c/d/e/deep.scm") "deep.scm"))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: detect-language
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "detect-language returns racket for .rkt extension"
  (check-equal? (detect-language "main.rkt") "racket"))

(test-case "detect-language returns racket for .scrbl extension"
  (check-equal? (detect-language "guide.scrbl") "racket"))

(test-case "detect-language returns racket for .rhm extension"
  (check-equal? (detect-language "demo.rhm") "racket"))

(test-case "detect-language returns plaintext for unknown extension"
  (check-equal? (detect-language "readme.txt") "plaintext"))

(test-case "detect-language returns plaintext for .js extension"
  (check-equal? (detect-language "app.js") "plaintext"))

(test-case "detect-language works with full path"
  (check-equal? (detect-language "/home/user/code/hello.rkt") "racket"))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: start-repl produces correct pty:create message
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "start-repl sends pty:create message"
  (reset-cells!)
  (define output
    (with-output-to-string
      (lambda () (start-repl))))
  (define msgs (parse-all-messages output))
  ;; start-repl sends pty:create then cell:update for status
  (define pty-msg (findf (lambda (m) (string=? (hash-ref m 'type) "pty:create")) msgs))
  (check-not-false pty-msg "pty:create message should be present")
  (check-equal? (hash-ref pty-msg 'id) "repl")
  (check-equal? (hash-ref pty-msg 'command) "racket")
  (check-equal? (hash-ref pty-msg 'cols) 80)
  (check-equal? (hash-ref pty-msg 'rows) 24))

(test-case "start-repl sets status cell to REPL started"
  (reset-cells!)
  (with-output-to-string
    (lambda () (start-repl)))
  (check-equal? (cell-ref 'status) "REPL started"))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: run-file produces correct pty:write message
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "run-file sends pty:write message with ,enter command"
  (reset-cells!)
  (define output
    (with-output-to-string
      (lambda () (run-file "/home/user/hello.rkt"))))
  (define msgs (parse-all-messages output))
  (define pty-msg (findf (lambda (m) (string=? (hash-ref m 'type) "pty:write")) msgs))
  (check-not-false pty-msg "pty:write message should be present")
  (check-equal? (hash-ref pty-msg 'id) "repl")
  (check-equal? (hash-ref pty-msg 'data) ",enter \"/home/user/hello.rkt\"\n"))

(test-case "run-file sets status cell to Running <path>"
  (reset-cells!)
  (with-output-to-string
    (lambda () (run-file "/tmp/test.rkt")))
  (check-equal? (cell-ref 'status) "Running /tmp/test.rkt"))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: handle-editor-event with editor:dirty
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "handle-editor-event with editor:dirty sets file-dirty to #t"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (handle-editor-event
       (make-message "event" 'name "editor:dirty"))))
  (check-equal? (cell-ref 'file-dirty) #t))

(test-case "handle-editor-event with editor:dirty updates title with dirty indicator"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "/home/user/demo.rkt")
      (handle-editor-event
       (make-message "event" 'name "editor:dirty"))))
  (check-equal? (cell-ref 'title) "MrRacket - demo.rkt *"))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: handle-file-result with file:read:result
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "handle-file-result with file:read:result updates current-file cell"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (handle-file-result
       (make-message "file:read:result"
                     'path "/home/user/hello.rkt"
                     'content "#lang racket\n(+ 1 2)"))))
  (check-equal? (cell-ref 'current-file) "/home/user/hello.rkt"))

(test-case "handle-file-result with file:read:result clears file-dirty"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'file-dirty #t)
      (handle-file-result
       (make-message "file:read:result"
                     'path "/home/user/hello.rkt"
                     'content "#lang racket\n"))))
  (check-equal? (cell-ref 'file-dirty) #f))

(test-case "handle-file-result with file:read:result updates title"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (handle-file-result
       (make-message "file:read:result"
                     'path "/home/user/hello.rkt"
                     'content ""))))
  (check-equal? (cell-ref 'title) "MrRacket - hello.rkt"))

(test-case "handle-file-result with file:read:result updates status"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (handle-file-result
       (make-message "file:read:result"
                     'path "/tmp/project/main.rkt"
                     'content ""))))
  (check-equal? (cell-ref 'status) "Opened main.rkt"))

(test-case "handle-file-result with file:read:result sends editor:open to frontend"
  (reset-cells!)
  (define output
    (with-output-to-string
      (lambda ()
        (handle-file-result
         (make-message "file:read:result"
                       'path "/home/user/demo.rhm"
                       'content "fun main(): 42")))))
  (define msgs (parse-all-messages output))
  (define editor-msg
    (findf (lambda (m) (string=? (hash-ref m 'type) "editor:open")) msgs))
  (check-not-false editor-msg "editor:open message should be present")
  (check-equal? (hash-ref editor-msg 'path) "/home/user/demo.rhm")
  (check-equal? (hash-ref editor-msg 'content) "fun main(): 42")
  (check-equal? (hash-ref editor-msg 'language) "racket"))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: handle-file-result with file:write:result
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "handle-file-result with file:write:result clears file-dirty"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'file-dirty #t)
      (handle-file-result
       (make-message "file:write:result"
                     'path "/home/user/saved.rkt"))))
  (check-equal? (cell-ref 'file-dirty) #f))

(test-case "handle-file-result with file:write:result updates status"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (handle-file-result
       (make-message "file:write:result"
                     'path "/home/user/saved.rkt"))))
  (check-equal? (cell-ref 'status) "Saved saved.rkt"))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: new-file resets state
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "new-file resets current-file to untitled.rkt"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'current-file "/some/old/path.rkt")
      (new-file)))
  (check-equal? (cell-ref 'current-file) "untitled.rkt"))

(test-case "new-file clears file-dirty"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (cell-set! 'file-dirty #t)
      (new-file)))
  (check-equal? (cell-ref 'file-dirty) #f))

(test-case "new-file sets title to MrRacket - untitled.rkt"
  (reset-cells!)
  (with-output-to-string
    (lambda () (new-file)))
  (check-equal? (cell-ref 'title) "MrRacket - untitled.rkt"))

(test-case "new-file sets status to New file"
  (reset-cells!)
  (with-output-to-string
    (lambda () (new-file)))
  (check-equal? (cell-ref 'status) "New file"))

(test-case "new-file sends editor:open with default racket content"
  (reset-cells!)
  (define output
    (with-output-to-string
      (lambda () (new-file))))
  (define msgs (parse-all-messages output))
  (define editor-msg
    (findf (lambda (m) (string=? (hash-ref m 'type) "editor:open")) msgs))
  (check-not-false editor-msg "editor:open message should be present")
  (check-equal? (hash-ref editor-msg 'path) "untitled.rkt")
  (check-equal? (hash-ref editor-msg 'content) "#lang racket\n\n")
  (check-equal? (hash-ref editor-msg 'language) "racket"))

;; ═══════════════════════════════════════════════════════════════════════════
;; Test: handle-repl-event with pty:exit
;; ═══════════════════════════════════════════════════════════════════════════

(test-case "handle-repl-event with pty:exit updates status"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (handle-repl-event
       (make-message "pty:exit" 'code 0))))
  (check-equal? (cell-ref 'status) "REPL exited (code 0)"))

(test-case "handle-repl-event with pty:exit non-zero code"
  (reset-cells!)
  (with-output-to-string
    (lambda ()
      (handle-repl-event
       (make-message "pty:exit" 'code 1))))
  (check-equal? (cell-ref 'status) "REPL exited (code 1)"))

(displayln "All Phase 2 tests passed!")
