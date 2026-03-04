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

;; ── Message dispatcher ─────────────────────────────────────
(define (dispatch msg)
  (define typ (message-type msg))
  (cond
    [(string=? typ "event") (handle-event msg)]
    [(string=? typ "ping")
     (send-message! (make-message "pong"))]
    [else
     (eprintf "Unknown message type: ~a\n" typ)]))

;; ── Startup sequence ───────────────────────────────────────
(register-all-cells!)
(send-message! (make-message "layout:set" 'layout initial-layout))
(send-message! (make-message "lifecycle:ready"))
(start-message-loop dispatch)
