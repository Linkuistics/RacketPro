#lang racket/base

;; stepper.rkt — Step-through execution using Racket's stepper library
;;
;; Uses stepper/private/model (the DrRacket stepper engine) to produce
;; before/after reduction steps for #lang racket programs. Each step
;; is sent as a JSON "stepper:step" message; when stepping finishes,
;; a "stepper:finished" message is emitted.
;;
;; Interactive stepping: the stepper thread blocks on a semaphore after
;; each step. stepper-forward posts to the semaphore to advance one step.
;; stepper-back replays a previous step from history. stepper-continue
;; switches to run-to-completion mode and unblocks the thread.

(require racket/port
         racket/string
         racket/format
         racket/file
         racket/list
         stepper/private/model
         stepper/private/model-settings
         stepper/private/shared-typed
         stepper/private/syntax-hider
         "protocol.rkt"
         "cell.rkt")

(provide start-stepper
         stop-stepper
         stepper-active?
         stepper-forward
         stepper-back
         stepper-continue
         extract-define-binding)

;; ── Internal state ──────────────────────────────────────────

(define _stepper-active #f)
(define _step-count 0)
(define _stepper-thread #f)
(define _bindings (make-hash))  ;; name-string -> value-string

;; Interactive stepping state
(define _step-gate (make-semaphore 0))    ;; gates the stepper thread
(define _step-history '())                ;; list of step data hasheqs (newest last)
(define _view-index 0)                    ;; 1-based index of currently viewed step
(define _stepping-mode 'step)             ;; 'step = pause each step, 'continue = run all

(define (stepper-active?) _stepper-active)

;; ── Bindings extraction ────────────────────────────────────

;; Check if a string looks like a completed define form: (define <name> <literal>)
;; Returns (list name-string value-string) or #f.
;; A "completed" define is one where the body is a literal value (no sub-expressions
;; remaining to evaluate). We match numbers, strings, booleans, symbols, and '().
(define (extract-define-binding str)
  (define m (regexp-match #rx"^\\(define ([^ )]+) (.+)\\)$" str))
  (and m
       (let ([val (caddr m)])
         ;; Only record if the value looks like a literal (not a compound expression)
         ;; Literals: numbers, booleans, quoted values, strings, '(), void
         (and (or (regexp-match? #rx"^-?[0-9]" val)          ;; number
                  (regexp-match? #rx"^#t$|^#f$" val)         ;; boolean
                  (regexp-match? #rx"^\"" val)                ;; string
                  (regexp-match? #rx"^'\\(" val)              ;; quoted list
                  (regexp-match? #rx"^'[^ ]" val)             ;; quoted symbol
                  (equal? val "'()")                           ;; empty list
                  (equal? val "(void)")                        ;; void
                  (equal? val "void"))                         ;; void
              (list (cadr m) val)))))

;; Convert the _bindings hash to a JSON-friendly list of {name, value} hashes
(define (bindings->list bindings)
  (for/list ([(name val) (in-hash bindings)])
    (hasheq 'name name 'value val)))

;; Scan post-exps strings for completed define forms and update _bindings
(define (update-bindings-from-post-exps! post-strs)
  (for ([s (in-list post-strs)])
    (define result (extract-define-binding s))
    (when result
      (hash-set! _bindings (car result) (cadr result)))))

;; ── Interactive stepping controls ──────────────────────────

;; Send the step message for a history entry (used by forward/back navigation)
(define (send-history-step! index)
  (define step-data (list-ref _step-history (sub1 index)))
  (set! _view-index index)
  (cell-set! 'stepper-step index)
  (send-message!
   (make-message "stepper:step"
                 'step index
                 'data step-data)))

;; Advance one step forward.
;; If viewing history (view-index < step-count), replay the next history entry.
;; If at the latest step, post to the semaphore to let the engine produce one more.
(define (stepper-forward)
  (when _stepper-active
    (cond
      ;; Viewing history — replay next entry
      [(< _view-index _step-count)
       (send-history-step! (add1 _view-index))]
      ;; At the latest step — unblock the engine for one more
      [else
       (semaphore-post _step-gate)])))

;; Go back one step in history.
;; Re-sends the previous step's data without touching the stepper thread.
(define (stepper-back)
  (when (and _stepper-active (> _view-index 1))
    (send-history-step! (sub1 _view-index))))

;; Switch to run-to-completion mode and unblock the engine.
(define (stepper-continue)
  (when _stepper-active
    (set! _stepping-mode 'continue)
    (semaphore-post _step-gate)))

;; ── Stop stepper ────────────────────────────────────────────

(define (stop-stepper)
  (when _stepper-thread
    ;; Unblock the thread if it's waiting on the gate, so break-thread can take effect
    (semaphore-post _step-gate)
    (when (thread-running? _stepper-thread)
      (break-thread _stepper-thread)
      ;; Give it a moment to die
      (sync/timeout 0.5 (thread-dead-evt _stepper-thread)))
    (set! _stepper-thread #f))
  (set! _stepper-active #f)
  (set! _step-count 0)
  (set! _step-history '())
  (set! _view-index 0)
  (set! _stepping-mode 'step)
  (hash-clear! _bindings)
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
    (semaphore-post _step-gate) ;; unblock if waiting
    (when (thread-running? _stepper-thread)
      (break-thread _stepper-thread)
      (sync/timeout 0.5 (thread-dead-evt _stepper-thread)))
    (set! _stepper-thread #f))

  (set! _stepper-active #t)
  (set! _step-count 0)
  (set! _step-history '())
  (set! _view-index 0)
  (set! _stepping-mode 'step)
  (set! _step-gate (make-semaphore 0))  ;; fresh semaphore for new session
  (hash-clear! _bindings)
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
                  (define post-strs (sstx-list->strings
                                     (Before-After-Result-post-exps r)))

                  ;; Update running bindings from any completed defines
                  (update-bindings-from-post-exps! post-strs)

                  (define step-data
                    (hasheq 'type "before-after"
                            'before (sstx-list->strings
                                     (Before-After-Result-pre-exps r))
                            'after post-strs
                            'kind (symbol->string
                                   (Before-After-Result-kind r))
                            'bindings (bindings->list _bindings)
                            'pre_src (if pre-src
                                         (hasheq 'position (Posn-Info-posn pre-src)
                                                 'span (Posn-Info-span pre-src))
                                         #f)
                            'post_src (if post-src
                                          (hasheq 'position (Posn-Info-posn post-src)
                                                  'span (Posn-Info-span post-src))
                                          #f)))

                  ;; Push onto history
                  (set! _step-history (append _step-history (list step-data)))
                  (set! _view-index _step-count)

                  (send-message!
                   (make-message "stepper:step"
                                'step _step-count
                                'data step-data))

                  ;; Gate: block if in step mode
                  (when (eq? _stepping-mode 'step)
                    (semaphore-wait _step-gate))]

                 [(Before-Error-Result? r)
                  (set! _step-count (add1 _step-count))
                  (cell-set! 'stepper-step _step-count)

                  (define pre-src (Before-Error-Result-pre-src r))

                  (define step-data
                    (hasheq 'type "before-error"
                            'before (sstx-list->strings
                                     (Before-Error-Result-pre-exps r))
                            'error (Before-Error-Result-err-msg r)
                            'pre_src (if pre-src
                                         (hasheq 'position (Posn-Info-posn pre-src)
                                                 'span (Posn-Info-span pre-src))
                                         #f)))

                  ;; Push onto history
                  (set! _step-history (append _step-history (list step-data)))
                  (set! _view-index _step-count)

                  (send-message!
                   (make-message "stepper:step"
                                'step _step-count
                                'data step-data))

                  ;; Gate: block if in step mode
                  (when (eq? _stepping-mode 'step)
                    (semaphore-wait _step-gate))]

                 [(Error-Result? r)
                  (set! _step-count (add1 _step-count))
                  (cell-set! 'stepper-step _step-count)

                  (define step-data
                    (hasheq 'type "error"
                            'error (Error-Result-err-msg r)))

                  ;; Push onto history
                  (set! _step-history (append _step-history (list step-data)))
                  (set! _view-index _step-count)

                  (send-message!
                   (make-message "stepper:step"
                                'step _step-count
                                'data step-data))

                  ;; Gate: block if in step mode
                  (when (eq? _stepping-mode 'step)
                    (semaphore-wait _step-gate))]

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
