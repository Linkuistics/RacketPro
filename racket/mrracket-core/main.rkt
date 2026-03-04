#lang racket/base

(require "protocol.rkt"
         "cell.rkt"
         "editor.rkt"
         "repl.rkt")

;; ── Cells ──────────────────────────────────────────────────
(define-cell current-file "untitled.rkt")
(define-cell file-dirty #f)
(define-cell title "MrRacket")
(define-cell status "starting")

;; ── Layout ─────────────────────────────────────────────────
(define initial-layout
  (hasheq 'type "vbox"
          'props (hasheq 'flex "1")
          'children
          (list
           ;; Toolbar
           (hasheq 'type "toolbar"
                   'props (hasheq)
                   'children
                   (list
                    (hasheq 'type "button"
                            'props (hasheq 'label "Run"
                                           'onClick "run"
                                           'variant "primary")
                            'children (list))
                    (hasheq 'type "text"
                            'props (hasheq 'text "cell:current-file"
                                           'style "mono")
                            'children (list))))
           ;; Split: editor + terminal
           (hasheq 'type "split"
                   'props (hasheq 'direction "vertical"
                                  'ratio 0.6)
                   'children
                   (list
                    (hasheq 'type "editor"
                            'props (hasheq 'file-path ""
                                           'language "racket")
                            'children (list))
                    (hasheq 'type "terminal"
                            'props (hasheq 'pty-id "repl")
                            'children (list)))))))

;; ── Menu ───────────────────────────────────────────────────
(define app-menu
  (list
   (hasheq 'label "File"
           'children
           (list
            (hasheq 'label "New" 'shortcut "Cmd+N" 'action "new-file")
            (hasheq 'label "Open..." 'shortcut "Cmd+O" 'action "open-file")
            (hasheq 'label "Save" 'shortcut "Cmd+S" 'action "save-file")
            (hasheq 'label "---")
            (hasheq 'label "Quit" 'shortcut "Cmd+Q" 'action "quit")))
   (hasheq 'label "Edit"
           'children
           (list
            (hasheq 'label "Undo" 'shortcut "Cmd+Z" 'action "undo")
            (hasheq 'label "Redo" 'shortcut "Cmd+Shift+Z" 'action "redo")))
   (hasheq 'label "Racket"
           'children
           (list
            (hasheq 'label "Run" 'shortcut "Cmd+R" 'action "run")))))

;; ── Event handler ──────────────────────────────────────────
(define (handle-event msg)
  (define event-name (message-ref msg 'name ""))
  (cond
    [(string=? event-name "run")
     (handle-run)]
    [(or (string=? event-name "editor:dirty")
         (string=? event-name "editor:save-request"))
     (handle-editor-event msg)]
    [else
     (eprintf "Unknown event: ~a\n" event-name)]))

;; ── Menu action handler ───────────────────────────────────
(define (handle-menu-action msg)
  (define action (message-ref msg 'action ""))
  (cond
    [(string=? action "quit") (exit 0)]
    [(string=? action "new-file") (new-file)]
    [(string=? action "open-file") (open-file)]
    [(string=? action "save-file") (void)] ;; save handled via frontend Cmd+S
    [(string=? action "run") (handle-run)]
    [else
     (eprintf "Unhandled menu action: ~a\n" action)]))

;; ── Run handler ────────────────────────────────────────────
(define (handle-run)
  (define path (current-file-path))
  (when (and path (not (string=? path "untitled.rkt")))
    (run-file path)))

;; ── Message dispatcher ─────────────────────────────────────
(define (dispatch msg)
  (define typ (message-type msg))
  (cond
    [(string=? typ "event") (handle-event msg)]
    [(string=? typ "menu:action") (handle-menu-action msg)]
    ;; File operation results from Rust
    [(or (string=? typ "file:read:result")
         (string=? typ "file:write:result")
         (string=? typ "file:read:error")
         (string=? typ "file:write:error")
         (string=? typ "file:open-dialog:cancelled")
         (string=? typ "file:save-dialog:cancelled"))
     (handle-file-result msg)]
    ;; PTY events
    [(string=? typ "pty:exit")
     (handle-repl-event msg)]
    [(string=? typ "ping")
     (send-message! (make-message "pong"))]
    [else
     (eprintf "Unknown message type: ~a\n" typ)]))

;; ── Startup sequence ───────────────────────────────────────
(register-all-cells!)
(send-message! (make-message "menu:set" 'menu app-menu))
(send-message! (make-message "layout:set" 'layout initial-layout))

;; Start REPL PTY
(start-repl)

;; Start with a blank file
(new-file)

(send-message! (make-message "lifecycle:ready"))
(start-message-loop dispatch)
