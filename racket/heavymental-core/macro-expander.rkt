#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/pretty
         racket/string
         macro-debugger/model/trace
         macro-debugger/model/reductions
         macro-debugger/model/steps
         macro-debugger/model/deriv
         "protocol.rkt"
         "cell.rkt")

(provide start-macro-expander
         stop-macro-expander)

;; ── State ─────────────────────────────────────────────────
(define _macro-active #f)
(define _step-counter 0)

(define (next-step-id!)
  (begin0
    (format "step-~a" _step-counter)
    (set! _step-counter (add1 _step-counter))))

;; ── Syntax utilities ──────────────────────────────────────

;; Pretty-print a syntax object to a compact string
(define (syntax->string stx)
  (define out (open-output-string))
  (pretty-write (syntax->datum stx) out)
  (string-trim (get-output-string out)))

;; Extract the macro name from a step by looking at the foci
;; in the before-state. The first focus is usually the form
;; whose head is the macro name.
(define (step-macro-name s)
  (define foci (state-foci (protostep-s1 s)))
  (if (and (pair? foci) (syntax? (car foci)))
      (let ([datum (syntax->datum (car foci))])
        (if (and (pair? datum) (symbol? (car datum)))
            (symbol->string (car datum))
            #f))
      #f))

;; Serialize a syntax object's position info
(define (syntax-loc stx)
  (define pos (syntax-position stx))
  (define spn (syntax-span stx))
  (if (and pos spn)
      (hasheq 'offset pos 'span spn)
      #f))

;; Serialize focus syntax objects as offset/span pairs
(define (serialize-foci foci-list)
  (for/list ([f (in-list foci-list)]
             #:when (and (syntax-position f) (syntax-span f)))
    (hasheq 'offset (syntax-position f)
            'span (syntax-span f))))

;; ── Step serialization ───────────────────────────────────

(define (step->json s)
  (define id (next-step-id!))
  (define type-sym (protostep-type s))
  (define before-stx (step-term1 s))
  (define after-stx (step-term2 s))
  (define s1 (protostep-s1 s))
  (define s2 (step-s2 s))

  (hasheq 'id id
          'type (symbol->string type-sym)
          'typeLabel (step-type->string type-sym)
          'macro (step-macro-name s)
          'before (syntax->string before-stx)
          'after (syntax->string after-stx)
          'beforeLoc (syntax-loc before-stx)
          'foci (serialize-foci (state-foci s1))
          'fociAfter (serialize-foci (state-foci s2))
          'seq (state-seq s1)))

;; ── Public API ────────────────────────────────────────────

(define (start-macro-expander path #:macro-only? [macro-only? #f])
  (set! _macro-active #t)
  (set! _step-counter 0)
  (cell-set! 'macro-active #t)

  (with-handlers ([exn:fail?
                    (lambda (e)
                      (send-message! (make-message "macro:error"
                                                   'error (exn-message e)))
                      (stop-macro-expander))])
    ;; Read the source file
    (define text (file->string path))
    (define port (open-input-string text))
    (port-count-lines! port)

    ;; Skip #lang line by reading it
    (with-handlers ([exn:fail? (lambda (e) (void))])
      (read-language port (lambda () #f)))

    ;; Read all remaining forms as syntax
    (define forms
      (let loop ([acc '()])
        (define stx (read-syntax path port))
        (if (eof-object? stx)
            (reverse acc)
            (loop (cons stx acc)))))

    ;; If no forms, emit empty steps
    (when (null? forms)
      (send-message! (make-message "macro:steps" 'steps (list)))
      (cell-set! 'current-bottom-tab "macros"))

    ;; Trace each top-level form and collect rewrite steps
    (unless (null? forms)
      (define all-rw-steps
        (apply append
               (for/list ([form (in-list forms)])
                 (with-handlers ([exn:fail? (lambda (e) (list))])
                   (parameterize ([current-namespace (make-base-namespace)])
                     (define-values (result deriv) (trace/result form))
                     (define rw-steps (filter rewrite-step? (reductions deriv)))
                     ;; Apply macro-only filter if requested
                     (if macro-only?
                         (filter (lambda (s) (eq? (protostep-type s) 'macro)) rw-steps)
                         rw-steps))))))

      ;; Serialize and send
      (define step-jsons (for/list ([s all-rw-steps]) (step->json s)))
      (send-message! (make-message "macro:steps" 'steps step-jsons))
      (cell-set! 'current-bottom-tab "macros"))))

(define (stop-macro-expander)
  (set! _macro-active #f)
  (cell-set! 'macro-active #f)
  (send-message! (make-message "macro:clear")))
