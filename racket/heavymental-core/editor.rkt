#lang racket/base

(require racket/list
         racket/match
         racket/set
         racket/string
         "protocol.rkt"
         "cell.rkt")

(provide handle-editor-event
         handle-file-result
         handle-tab-close-request
         handle-dialog-result
         open-file
         save-current-file
         new-file
         current-file-path
         current-file-dirty?
         path->filename
         detect-language
         detect-lang-from-content
         mark-file-dirty!
         mark-file-clean!
         file-dirty?
         any-dirty-files?
         reset-dirty-state!
         set-pending-close!
         pending-close?
         clear-pending-close!)

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
    [(regexp-match? #rx"\\.rhm$" path) "rhombus"]
    [(regexp-match? #rx"\\.js$" path) "javascript"]
    [(regexp-match? #rx"\\.ts$" path) "typescript"]
    [(regexp-match? #rx"\\.rs$" path) "rust"]
    [(regexp-match? #rx"\\.toml$" path) "toml"]
    [(regexp-match? #rx"\\.json$" path) "json"]
    [(regexp-match? #rx"\\.css$" path) "css"]
    [(regexp-match? #rx"\\.html?$" path) "html"]
    [(regexp-match? #rx"\\.md$" path) "markdown"]
    [else "plaintext"]))

;; Detect language from #lang line in file content
(define (detect-lang-from-content content)
  (define m (regexp-match #rx"^#lang ([^ \r\n]+)" content))
  (and m (cadr m)))

;; Human-readable language name for the status bar
(define (language-display-name lang-id)
  (cond
    [(string=? lang-id "racket") "Racket"]
    [(string=? lang-id "rhombus") "Rhombus"]
    [(string=? lang-id "javascript") "JavaScript"]
    [(string=? lang-id "typescript") "TypeScript"]
    [(string=? lang-id "rust") "Rust"]
    [(string=? lang-id "toml") "TOML"]
    [(string=? lang-id "json") "JSON"]
    [(string=? lang-id "css") "CSS"]
    [(string=? lang-id "html") "HTML"]
    [(string=? lang-id "markdown") "Markdown"]
    [(string=? lang-id "plaintext") "Plain Text"]
    [else lang-id]))

;; ── Dirty file tracking ─────────────────────────────────────
;; Mutable set of file paths with unsaved changes.
;; The dirty-files cell is maintained as a JSON-friendly list.
(define dirty-set (mutable-set))

(define (mark-file-dirty! path)
  (set-add! dirty-set path)
  (sync-dirty-cell!))

(define (mark-file-clean! path)
  (set-remove! dirty-set path)
  (sync-dirty-cell!))

(define (file-dirty? path)
  (set-member? dirty-set path))

(define (any-dirty-files?)
  (positive? (set-count dirty-set)))

(define (reset-dirty-state!)
  (set-clear! dirty-set)
  (sync-dirty-cell!))

(define (sync-dirty-cell!)
  (cell-set! 'dirty-files (set->list dirty-set)))

;; ── Pending actions ─────────────────────────────────────────────
(define _pending-close-paths (mutable-set))

(define (set-pending-close! path) (set-add! _pending-close-paths path))
(define (pending-close? path) (set-member? _pending-close-paths path))
(define (clear-pending-close! path) (set-remove! _pending-close-paths path))

;; ── Tab close with dirty check ─────────────────────────────────

(define (handle-tab-close-request path)
  (cond
    [(file-dirty? path)
     (define filename (path->filename path))
     (send-message! (make-message "dialog:confirm"
                                  'id (format "close:~a" path)
                                  'title "Save Changes"
                                  'message (format "Do you want to save changes to ~a?" filename)
                                  'save_label "Save"
                                  'dont_save_label "Don't Save"
                                  'path path))]
    [else
     (send-message! (make-message "tab:close" 'path path))]))

(define (handle-dialog-result msg)
  (define id (message-ref msg 'id ""))
  (define choice (message-ref msg 'choice "cancel"))
  (cond
    [(string-prefix? id "close:")
     (define path (substring id 6))
     (cond
       [(string=? choice "save")
        (send-message! (make-message "editor:request-save"))
        (set-pending-close! path)]
       [(string=? choice "dont-save")
        (mark-file-clean! path)
        (send-message! (make-message "tab:close" 'path path))]
       [else (void)])]  ;; cancel — do nothing
    [else (void)]))

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
  (cell-set! 'language "Racket")
  (cell-set! 'title "HeavyMental — untitled.rkt")
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
     (define path (message-ref msg 'path (current-file-path)))
     (mark-file-dirty! path)
     (cell-set! 'file-dirty #t)
     ;; Update title to show dirty indicator
     (define filename (path->filename (current-file-path)))
     (cell-set! 'title (format "HeavyMental — ~a *" filename))]

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
     ;; Detect language: prefer #lang line, fall back to extension
     (define lang-from-content (detect-lang-from-content content))
     (define lang
       (cond
         [(and lang-from-content (string=? lang-from-content "rhombus")) "rhombus"]
         [(and lang-from-content (string-prefix? lang-from-content "typed/")) "racket"]
         [lang-from-content "racket"]  ;; any #lang → racket for now
         [else (detect-language path)]))
     (cell-set! 'current-file path)
     (cell-set! 'file-dirty #f)
     (cell-set! 'language (language-display-name lang))
     (define filename (path->filename path))
     (cell-set! 'title (format "HeavyMental — ~a" filename))
     (cell-set! 'status (format "Opened ~a" filename))
     (send-message! (make-message "editor:open"
                                  'path path
                                  'content content
                                  'language lang))]

    ["file:write:result"
     ;; Rust wrote the file successfully
     (define path (message-ref msg 'path ""))
     (cell-set! 'current-file path)
     (cell-set! 'file-dirty #f)
     (mark-file-clean! path)
     (define filename (path->filename path))
     (cell-set! 'title (format "HeavyMental — ~a" filename))
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
