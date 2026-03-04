#lang racket/base

(require racket/list
         racket/match
         "protocol.rkt"
         "cell.rkt")

(provide handle-editor-event
         handle-file-result
         open-file
         save-current-file
         new-file
         current-file-path
         current-file-dirty?
         path->filename
         detect-language)

;; ── Accessors for cell state ─────────────────────────────────
;; These read from cells defined in main.rkt via cell-ref.

(define (current-file-path)
  (cell-ref 'current-file))

(define (current-file-dirty?)
  (cell-ref 'file-dirty))

;; ── Helpers ──────────────────────────────────────────────────

;; Extract filename from full path
(define (path->filename path)
  (define parts (regexp-split #rx"[/\\\\]" path))
  (if (null? parts) path (last parts)))

;; Detect language from file extension
(define (detect-language path)
  (cond
    [(regexp-match? #rx"\\.rkt$" path) "racket"]
    [(regexp-match? #rx"\\.scrbl$" path) "racket"]
    [(regexp-match? #rx"\\.rhm$" path) "racket"]
    [else "plaintext"]))

;; ── File operations ──────────────────────────────────────────

;; Send a request to Rust to show the native open-file dialog.
;; Rust will read the file and send back a file:read:result message.
(define (open-file)
  (send-message! (make-message "file:open-dialog")))

;; Save the current file. If a path is already known, send file:write
;; directly. Otherwise, trigger a save-as dialog.
(define (save-current-file content)
  (define path (current-file-path))
  (cond
    [(or (not path) (string=? path "untitled.rkt"))
     ;; No path yet — ask Rust to show a save-as dialog
     (send-message! (make-message "file:save-dialog"
                                  'content content))]
    [else
     ;; Path is known — write directly
     (send-message! (make-message "file:write"
                                  'path path
                                  'content content))]))

;; Reset state for a new, blank file.
(define (new-file)
  (cell-set! 'current-file "untitled.rkt")
  (cell-set! 'file-dirty #f)
  (cell-set! 'title "MrRacket - untitled.rkt")
  (cell-set! 'status "New file")
  (send-message! (make-message "editor:open"
                               'path "untitled.rkt"
                               'content "#lang racket\n\n"
                               'language "racket")))

;; ── Event handlers ───────────────────────────────────────────

;; Handle editor events from the frontend (type "editor:*").
;; Dispatches on the event name.
(define (handle-editor-event msg)
  (define name (message-ref msg 'name ""))
  (match name
    ["editor:dirty"
     ;; Frontend reports the buffer is dirty
     (cell-set! 'file-dirty #t)
     ;; Update title to show dirty indicator
     (define filename (path->filename (current-file-path)))
     (cell-set! 'title (format "MrRacket - ~a *" filename))]

    ["editor:save-request"
     ;; Frontend requests a save (e.g., Cmd+S)
     (define content (message-ref msg 'content ""))
     (save-current-file content)]

    [_
     (eprintf "editor: unknown editor event: ~a\n" name)]))

;; Handle file operation results from Rust (type "file:*").
;; Dispatches on the message type.
(define (handle-file-result msg)
  (define typ (message-type msg))
  (match typ
    ["file:read:result"
     ;; Rust read a file successfully — update state and tell frontend
     (define path (message-ref msg 'path ""))
     (define content (message-ref msg 'content ""))
     (cell-set! 'current-file path)
     (cell-set! 'file-dirty #f)
     (define filename (path->filename path))
     (cell-set! 'title (format "MrRacket - ~a" filename))
     (cell-set! 'status (format "Opened ~a" filename))
     (send-message! (make-message "editor:open"
                                  'path path
                                  'content content
                                  'language (detect-language path)))]

    ["file:write:result"
     ;; Rust wrote the file successfully
     (define path (message-ref msg 'path ""))
     (cell-set! 'current-file path)
     (cell-set! 'file-dirty #f)
     (define filename (path->filename path))
     (cell-set! 'title (format "MrRacket - ~a" filename))
     (cell-set! 'status (format "Saved ~a" filename))]

    ["file:read:error"
     (define error-msg (message-ref msg 'error "Unknown error"))
     (cell-set! 'status (format "Error: ~a" error-msg))
     (eprintf "editor: file read error: ~a\n" error-msg)]

    ["file:write:error"
     (define error-msg (message-ref msg 'error "Unknown error"))
     (cell-set! 'status (format "Error: ~a" error-msg))
     (eprintf "editor: file write error: ~a\n" error-msg)]

    ["file:open-dialog:cancelled"
     (cell-set! 'status "Cancelled")]

    ["file:save-dialog:cancelled"
     (cell-set! 'status "Cancelled")]

    [_
     (eprintf "editor: unknown file result type: ~a\n" typ)]))
