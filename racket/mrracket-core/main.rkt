#lang racket/base

(require "protocol.rkt"
         "cell.rkt")

;; ── Cells ──────────────────────────────────────────────────
(define-cell counter 0)
(define-cell title "MrRacket")
(define-cell status "ready")

;; ── Layout ─────────────────────────────────────────────────
(define initial-layout
  (hasheq 'type "vbox"
          'props (hasheq 'padding 16 'gap 12)
          'children
          (list
           (hasheq 'type "heading"
                   'props (hasheq 'text "cell:title"))
           (hasheq 'type "text"
                   'props (hasheq 'text "cell:status"))
           (hasheq 'type "hbox"
                   'props (hasheq 'gap 8)
                   'children
                   (list
                    (hasheq 'type "button"
                            'props (hasheq 'label "Increment"
                                           'onClick "increment"))
                    (hasheq 'type "button"
                            'props (hasheq 'label "Reset"
                                           'onClick "reset"))))
           (hasheq 'type "text"
                   'props (hasheq 'text "cell:counter"
                                  'style "mono")))))

;; ── Menu definition ─────────────────────────────────────────
(define app-menu
  (list
   (hasheq 'label "File"
           'children
           (list
            (hasheq 'label "New" 'shortcut "Cmd+N" 'action "new-file")
            (hasheq 'label "Open..." 'shortcut "Cmd+O" 'action "open-file")
            (hasheq 'label "---")
            (hasheq 'label "Quit" 'shortcut "Cmd+Q" 'action "quit")))
   (hasheq 'label "Edit"
           'children
           (list
            (hasheq 'label "Undo" 'shortcut "Cmd+Z" 'action "undo")
            (hasheq 'label "Redo" 'shortcut "Cmd+Shift+Z" 'action "redo")))))

;; ── Event handler ──────────────────────────────────────────
(define (handle-event msg)
  (define event-name (message-ref msg 'name ""))
  (cond
    [(string=? event-name "increment")
     (cell-update! 'counter add1)
     (cell-set! 'status
                (format "counter is now ~a" (cell-ref 'counter)))]
    [(string=? event-name "reset")
     (cell-set! 'counter 0)
     (cell-set! 'status "ready")]
    [else
     (eprintf "Unknown event: ~a\n" event-name)]))

;; ── Menu action handler ─────────────────────────────────────
(define (handle-menu-action msg)
  (define action (message-ref msg 'action ""))
  (cond
    [(string=? action "quit")
     (eprintf "Quit requested via menu\n")
     (exit 0)]
    [(string=? action "new-file")
     (cell-set! 'status "New file (not yet implemented)")]
    [(string=? action "open-file")
     (cell-set! 'status "Open file (not yet implemented)")]
    [else
     (eprintf "Unhandled menu action: ~a\n" action)]))

;; ── Message dispatcher ─────────────────────────────────────
(define (dispatch msg)
  (define typ (message-type msg))
  (cond
    [(string=? typ "event") (handle-event msg)]
    [(string=? typ "menu:action") (handle-menu-action msg)]
    [(string=? typ "ping")
     (send-message! (make-message "pong"))]
    [else
     (eprintf "Unknown message type: ~a\n" typ)]))

;; ── Startup sequence ───────────────────────────────────────
(register-all-cells!)
(send-message! (make-message "menu:set" 'menu app-menu))
(send-message! (make-message "layout:set" 'layout initial-layout))
(send-message! (make-message "lifecycle:ready"))
(start-message-loop dispatch)
