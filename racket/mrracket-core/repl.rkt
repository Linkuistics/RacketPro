#lang racket/base

(require racket/match
         "protocol.rkt"
         "cell.rkt")

(provide start-repl
         run-file
         handle-repl-event)

;; ── REPL lifecycle ───────────────────────────────────────────

;; Send a request to Rust to create a PTY running a Racket REPL.
;; Rust will spawn the process and connect it to the frontend terminal.
(define (start-repl)
  (send-message! (make-message "pty:create"
                               'command "racket"
                               'args (list)))
  (cell-set! 'status "REPL started"))

;; Send a `,enter "<path>"` command to the REPL PTY so that
;; Racket loads the file's definitions into the interaction namespace.
(define (run-file path)
  (define cmd (format ",enter \"~a\"\n" path))
  (send-message! (make-message "pty:write"
                               'data cmd))
  (cell-set! 'status (format "Running ~a" path)))

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
