#lang racket/base

;; stepper.rkt — Step-through execution using Racket's stepper library
;;
;; Uses stepper/private/model (the DrRacket stepper engine) to produce
;; before/after reduction steps for #lang racket programs. Each step
;; is sent as a JSON "stepper:step" message; when stepping finishes,
;; a "stepper:finished" message is emitted.

(require racket/port
         racket/string
         racket/format
         racket/file
         stepper/private/model
         stepper/private/model-settings
         stepper/private/shared-typed
         stepper/private/syntax-hider
         "protocol.rkt"
         "cell.rkt")

(provide start-stepper
         stop-stepper
         stepper-active?)

;; ── Internal state ──────────────────────────────────────────

(define _stepper-active #f)
(define _step-count 0)
(define _stepper-thread #f)

(define (stepper-active?) _stepper-active)

;; ── Stop stepper ────────────────────────────────────────────

(define (stop-stepper)
  (when _stepper-thread
    (when (thread-running? _stepper-thread)
      (break-thread _stepper-thread)
      ;; Give it a moment to die
      (sync/timeout 0.5 (thread-dead-evt _stepper-thread)))
    (set! _stepper-thread #f))
  (set! _stepper-active #f)
  (set! _step-count 0)
  (cell-set! 'stepper-active #f)
  (cell-set! 'stepper-step 0)
  (cell-set! 'stepper-total -1)
  (send-message! (make-message "stepper:finished"
                               'total _step-count)))

;; ── Render a syntax list to a string list ───────────────────

(define (sstx-list->strings lst)
  (for/list ([s (in-list lst)])
    (format "~a" (syntax->datum (sstx-s s)))))

;; ── Start stepper ───────────────────────────────────────────

(define (start-stepper file-path)
  ;; Clean up any previous session (but don't send finished message)
  (when _stepper-thread
    (when (thread-running? _stepper-thread)
      (break-thread _stepper-thread)
      (sync/timeout 0.5 (thread-dead-evt _stepper-thread)))
    (set! _stepper-thread #f))

  (set! _stepper-active #t)
  (set! _step-count 0)
  (cell-set! 'stepper-active #t)
  (cell-set! 'stepper-step 0)
  (cell-set! 'stepper-total -1)
  (cell-set! 'status (format "Stepping ~a" file-path))

  ;; Run stepper in a thread so it doesn't block the message loop
  (set! _stepper-thread
        (thread
         (lambda ()
           (with-handlers
               ([exn:break?
                 (lambda (e)
                   ;; Stopped by stop-stepper — do nothing, it will clean up
                   (void))]
                [exn:fail?
                 (lambda (e)
                   (send-message! (make-message "stepper:error"
                                                'error (exn-message e)))
                   (set! _stepper-active #f)
                   (cell-set! 'stepper-active #f)
                   (cell-set! 'status "Stepper error"))])

             ;; Read the source file
             (define source-text (file->string file-path))
             (define in (open-input-string source-text))
             (port-count-lines! in)

             ;; Skip the #lang line
             (read-line in)

             ;; Set up a namespace for expansion
             (define ns (make-base-namespace))

             ;; Receive results callback — called by the stepper engine
             (define (receive-result r)
               (cond
                 [(Before-After-Result? r)
                  (set! _step-count (add1 _step-count))
                  (cell-set! 'stepper-step _step-count)

                  (define pre-src (Before-After-Result-pre-src r))
                  (define post-src (Before-After-Result-post-src r))

                  (send-message!
                   (make-message "stepper:step"
                                'step _step-count
                                'data
                                (hasheq 'type "before-after"
                                        'before (sstx-list->strings
                                                 (Before-After-Result-pre-exps r))
                                        'after (sstx-list->strings
                                                (Before-After-Result-post-exps r))
                                        'kind (symbol->string
                                               (Before-After-Result-kind r))
                                        'pre_src (if pre-src
                                                     (hasheq 'position (Posn-Info-posn pre-src)
                                                             'span (Posn-Info-span pre-src))
                                                     #f)
                                        'post_src (if post-src
                                                      (hasheq 'position (Posn-Info-posn post-src)
                                                              'span (Posn-Info-span post-src))
                                                      #f))))]
                 [(Before-Error-Result? r)
                  (set! _step-count (add1 _step-count))
                  (cell-set! 'stepper-step _step-count)

                  (define pre-src (Before-Error-Result-pre-src r))

                  (send-message!
                   (make-message "stepper:step"
                                'step _step-count
                                'data
                                (hasheq 'type "before-error"
                                        'before (sstx-list->strings
                                                 (Before-Error-Result-pre-exps r))
                                        'error (Before-Error-Result-err-msg r)
                                        'pre_src (if pre-src
                                                     (hasheq 'position (Posn-Info-posn pre-src)
                                                             'span (Posn-Info-span pre-src))
                                                     #f))))]
                 [(Error-Result? r)
                  (set! _step-count (add1 _step-count))
                  (cell-set! 'stepper-step _step-count)

                  (send-message!
                   (make-message "stepper:step"
                                'step _step-count
                                'data
                                (hasheq 'type "error"
                                        'error (Error-Result-err-msg r))))]
                 [(eq? r 'finished-stepping)
                  ;; Stepper engine signals completion
                  (cell-set! 'stepper-total _step-count)
                  (cell-set! 'stepper-active #f)
                  (cell-set! 'status "Stepping complete")
                  (set! _stepper-active #f)
                  (send-message! (make-message "stepper:finished"
                                               'total _step-count))]
                 [else (void)]))

             ;; Program expander: reads each top-level form from the file,
             ;; expands it, and feeds it to the stepper engine
             (define (program-expander init iter)
               (init)
               (let loop ()
                 (define stx (read-syntax file-path in))
                 (cond
                   [(eof-object? stx)
                    (iter eof void)]
                   [else
                    (define expanded
                      (parameterize ([current-namespace ns])
                        (expand stx)))
                    (iter expanded (lambda () (loop)))])))

             ;; Run the stepper engine
             (go program-expander
                 void                        ; dynamic-requirer
                 receive-result
                 fake-mz-render-settings))))))
