#lang racket/base

(require racket/list
         racket/match
         racket/set
         racket/string
         "protocol.rkt"
         "cell.rkt"
         "lang-intel.rkt")

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
         clear-pending-close!
         pending-run?
         set-pending-run!
         clear-pending-run!
         pending-quit?
         set-pending-quit!
         clear-pending-quit!
         set-pending-goto!
         pending-goto
         clear-pending-goto!
         handle-close-request)

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

;; ── Pending run state ─────────────────────────────────────────────
;; When the user hits Run on a dirty file, we save first and set
;; pending-run so that the file:write:result handler can trigger the run.
(define _pending-run #f)

(define (pending-run?) _pending-run)
(define (set-pending-run!) (set! _pending-run #t))
(define (clear-pending-run!) (set! _pending-run #f))

;; ── Pending quit state ───────────────────────────────────────────────
;; When the user chooses "Save" in the quit-confirmation dialog, we save
;; the current file and set pending-quit so that the file:write:result
;; handler can send lifecycle:quit after the save completes.
(define _pending-quit #f)

(define (pending-quit?) _pending-quit)
(define (set-pending-quit!) (set! _pending-quit #t))
(define (clear-pending-quit!) (set! _pending-quit #f))

;; ── Pending goto state ───────────────────────────────────────────────
;; When a file needs to be opened and then jumped to a position,
;; we queue the goto here. file:read:result handler checks this.
(define _pending-goto #f)

(define (set-pending-goto! path #:line [line #f] #:col [col #f] #:name [name #f])
  (set! _pending-goto (hasheq 'path path
                               'line (or line #f)
                               'col (or col #f)
                               'name (or name #f))))

(define (pending-goto) _pending-goto)
(define (clear-pending-goto!) (set! _pending-goto #f))

;; ── Window close request handler ───────────────────────────────
;; Called when Rust intercepts the window close event.
;; If there are dirty files, shows a save dialog; otherwise quits.

(define (handle-close-request)
  (cond
    [(any-dirty-files?)
     (send-message! (make-message "dialog:confirm"
                                  'id "lifecycle:quit"
                                  'title "Unsaved Changes"
                                  'message "You have unsaved changes. Save before quitting?"
                                  'save_label "Save"
                                  'dont_save_label "Don\u2019t Save"
                                  'cancel_label "Cancel"))]
    [else
     (send-message! (make-message "lifecycle:quit"))]))

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
    [(string=? id "lifecycle:quit")
     (cond
       [(string=? choice "save")
        (send-message! (make-message "editor:request-save"))
        (set-pending-quit!)]
       [(string=? choice "dont-save")
        (send-message! (make-message "lifecycle:quit"))]
       [else (void)])]  ;; cancel — do nothing (window stays open)
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
                                  'language lang))
     ;; Check for pending goto
     (define pg (pending-goto))
     (when (and pg (string=? (hash-ref pg 'path "") path))
       (cond
         ;; Goto with known line/col (e.g., REPL error jump)
         [(hash-ref pg 'line #f)
          (send-message! (make-message "editor:goto"
                                       'line (hash-ref pg 'line 1)
                                       'col (hash-ref pg 'col 0)))]
         ;; Goto with symbol name (cross-file definition) — need check-syntax
         [(hash-ref pg 'name #f)
          ;; Analyze the target file to find where the symbol is defined
          (define name (hash-ref pg 'name))
          (define result (analyze-source path content))
          (define defs (hash-ref result 'definitions '()))
          (define match
            (for/first ([d (in-list defs)]
                        #:when (string=? (hash-ref d 'name "") name))
              d))
          (when match
            (define range (offsets->range content
                                          (hash-ref match 'from 0)
                                          (hash-ref match 'to 1)))
            (send-message! (make-message "editor:goto"
                                         'line (hash-ref range 'startLine 1)
                                         'col (hash-ref range 'startCol 0))))])
       (clear-pending-goto!))]

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
