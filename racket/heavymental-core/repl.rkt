#lang racket/base

(require racket/match
         "protocol.rkt"
         "cell.rkt")

(provide start-repl
         run-file
         clear-repl
         restart-repl
         repl-generation
         handle-repl-event)

;; ── REPL lifecycle ───────────────────────────────────────────

;; Generation counter: incremented each time a new REPL is created.
;; Used to ignore pty:exit events from stale (killed) REPL processes.
(define _repl-gen 0)

(define (repl-generation) _repl-gen)

;; Send a request to Rust to create a PTY running a Racket REPL.
;; Rust will spawn the process and connect it to the frontend terminal.
(define (start-repl)
  (set! _repl-gen (add1 _repl-gen))
  (send-message! (make-message "pty:create"
                               'id "repl"
                               'command "racket"
                               'args (list)
                               'cols 80
                               'rows 24))
  (cell-set! 'status "REPL started"))

;; Send a `,enter (file "<path>")` command to the REPL PTY so that
;; Racket loads the file's definitions into the interaction namespace.
(define (run-file path)
  (define cmd (format ",enter (file \"~a\")\n" path))
  (send-message! (make-message "pty:write"
                               'id "repl"
                               'data cmd))
  (cell-set! 'status (format "Running ~a" path)))

;; Clear the REPL terminal (send Ctrl+L / form feed)
(define (clear-repl)
  (send-message! (make-message "pty:write"
                               'id "repl"
                               'data "\x0c")))

;; Restart the REPL (kill + recreate)
;; Note: the new start-repl increments the generation, so any
;; pty:exit from the killed REPL will be ignored by the dispatcher.
(define (restart-repl)
  (send-message! (make-message "pty:kill" 'id "repl"))
  (start-repl))

;; ── Event handler ────────────────────────────────────────────

;; Handle REPL/PTY events from Rust.
(define (handle-repl-event msg)
  (define typ (message-type msg))
  (match typ
    ["pty:exit"
     ;; The REPL process exited
     (define code (message-ref msg 'code 0))
     (cell-set! 'status (format "REPL exited (code ~a)" code))]

    [_
     (eprintf "repl: unknown repl event type: ~a\n" typ)]))
