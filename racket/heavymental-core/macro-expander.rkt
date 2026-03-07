#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/pretty
         racket/string
         syntax/parse
         "protocol.rkt"
         "cell.rkt")

(provide start-macro-expander
         stop-macro-expander)

;; ── State ─────────────────────────────────────────────────
(define _macro-active #f)
(define _node-counter 0)

(define (next-node-id!)
  (set! _node-counter (add1 _node-counter))
  (format "node-~a" _node-counter))

;; ── Syntax utilities ──────────────────────────────────────

;; Pretty-print a syntax object to a string
(define (syntax->string stx)
  (define out (open-output-string))
  (pretty-write (syntax->datum stx) out)
  (string-trim (get-output-string out)))

;; Get the head identifier of a syntax list, if any
(define (syntax-head stx)
  (syntax-case stx ()
    [(head . _) (identifier? #'head) (symbol->string (syntax-e #'head))]
    [_ #f]))

;; Check if two syntax objects are identical (no expansion happened).
;; Also treats (quote X) as unchanged if X equals the original datum,
;; since expand-once turns literals like #t into '#t.
(define (syntax-unchanged? before after)
  (define bd (syntax->datum before))
  (define ad (syntax->datum after))
  (or (equal? bd ad)
      ;; (quote X) where X = original datum is just literal quotation, not a real macro step
      (and (pair? ad)
           (eq? (car ad) 'quote)
           (pair? (cdr ad))
           (null? (cddr ad))
           (equal? bd (cadr ad)))))

;; ── Expansion tree builder ────────────────────────────────

;; Maximum recursion depth for expansion tracing
(define MAX-EXPANSION-DEPTH 50)

;; expand-and-trace: recursively expand a syntax object,
;; building a tree of macro applications.
;;
;; Returns: hasheq with keys:
;;   'id       — unique node id
;;   'macro    — name of macro applied (or #f if leaf)
;;   'before   — string of form before expansion
;;   'after    — string of form after expansion (or #f if leaf)
;;   'children — list of child nodes
(define (expand-and-trace stx ns [depth 0])
  (define id (next-node-id!))
  (define before-str (syntax->string stx))

  ;; Bail out if we've recursed too deep
  (cond
    [(>= depth MAX-EXPANSION-DEPTH)
     (hasheq 'id id
             'macro #f
             'before before-str
             'after #f
             'children (list))]
    [else
     ;; Try expand-once
     (define expanded
       (with-handlers ([exn:fail? (lambda (e) stx)])
         (parameterize ([current-namespace ns])
           (expand-once stx))))

     (cond
       ;; No expansion happened — leaf node
       [(syntax-unchanged? stx expanded)
        (hasheq 'id id
                'macro #f
                'before before-str
                'after #f
                'children (list))]

       ;; Expansion happened — record it and recurse
       [else
        (define macro-name (or (syntax-head stx) "???"))
        (define after-str (syntax->string expanded))

        ;; Recursively trace the sub-expressions of the expanded form
        (define children
          (syntax-case expanded ()
            [(parts ...)
             (for/list ([part (in-list (syntax->list #'(parts ...)))])
               (expand-and-trace part ns (add1 depth)))]
            [_ (list)]))

        ;; Filter out leaf children with no macro application
        ;; (keep the tree focused on actual macro steps)
        (define interesting-children
          (filter (lambda (c) (or (hash-ref c 'macro #f)
                                  (not (null? (hash-ref c 'children '())))))
                  children))

        (hasheq 'id id
                'macro macro-name
                'before before-str
                'after after-str
                'children interesting-children)])]))

;; ── Public API ────────────────────────────────────────────

(define (start-macro-expander path)
  (set! _macro-active #t)
  (set! _node-counter 0)
  (cell-set! 'macro-active #t)

  (with-handlers ([exn:fail?
                   (lambda (e)
                     (send-message! (make-message "macro:error"
                                                  'error (exn-message e)))
                     (stop-macro-expander))])
    ;; Read and parse the source file
    (define text (file->string path))
    (define port (open-input-string text))
    (port-count-lines! port)

    ;; Consume #lang line if present — read-language handles #lang
    ;; and returns a reader function; we just need it to advance the port
    (with-handlers ([exn:fail? (lambda (e) (void))])
      (read-language port (lambda () #f)))

    ;; Set up namespace for expansion
    (define ns (make-base-namespace))

    ;; Read and expand each top-level form
    (define forms
      (let loop ([acc '()])
        (define stx (read-syntax path port))
        (if (eof-object? stx)
            (reverse acc)
            (loop (cons (expand-and-trace stx ns) acc)))))

    ;; Send the expansion tree to frontend
    (send-message! (make-message "macro:tree" 'forms forms))
    (cell-set! 'current-bottom-tab "macros")))

(define (stop-macro-expander)
  (set! _macro-active #f)
  (cell-set! 'macro-active #f)
  (send-message! (make-message "macro:clear")))
