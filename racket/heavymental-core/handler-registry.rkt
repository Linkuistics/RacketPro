#lang racket/base
(require racket/string)
(provide register-auto-handler!
         get-auto-handler
         clear-auto-handlers!
         collect-handler-ids
         remove-handlers!
         ui-resolve-handler)

(define auto-handlers (make-hash))  ;; string "_h:N" -> procedure
(define handler-counter 0)

(define (register-auto-handler! proc)
  (set! handler-counter (add1 handler-counter))
  (define id (format "_h:~a" handler-counter))
  ;; Wrap to handle arity: if proc takes 0 args, ignore the msg
  (define wrapped
    (if (procedure-arity-includes? proc 1)
        proc
        (lambda (msg) (proc))))
  (hash-set! auto-handlers id wrapped)
  id)

(define (get-auto-handler id)
  (hash-ref auto-handlers id #f))

(define (clear-auto-handlers!)
  (hash-clear! auto-handlers)
  (set! handler-counter 0))

(define (remove-handlers! ids)
  (for ([id (in-list ids)])
    (hash-remove! auto-handlers id)))

;; Walk a layout tree and collect all _h: handler IDs from props
(define (collect-handler-ids layout)
  (cond
    [(not (hash? layout)) '()]
    [else
     (define props (hash-ref layout 'props (hasheq)))
     (define prop-ids
       (for/list ([(k v) (in-hash props)]
                  #:when (and (string? v) (string-prefix? v "_h:")))
         v))
     (define children (hash-ref layout 'children '()))
     (define child-ids
       (apply append (map collect-handler-ids children)))
     (append prop-ids child-ids)]))

;; Resolve a handler value: strings pass through, procedures get auto-registered
(define (ui-resolve-handler val)
  (cond
    [(string? val) val]
    [(procedure? val) (register-auto-handler! val)]
    [else (error 'ui "handler must be a string or procedure, got: ~v" val)]))
