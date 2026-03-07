#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/pretty
         racket/string
         racket/struct
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
(define _tree-counter 0)

(define (next-step-id!)
  (begin0
    (format "step-~a" _step-counter)
    (set! _step-counter (add1 _step-counter))))

(define (next-tree-id!)
  (begin0
    (format "node-~a" _tree-counter)
    (set! _tree-counter (add1 _tree-counter))))

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

;; Serialize foci relative to a base position (for highlighting in original source)
(define (serialize-foci-relative foci-list base-pos)
  (for/list ([f (in-list foci-list)]
             #:when (and (syntax-position f) (syntax-span f) base-pos))
    (hasheq 'offset (- (syntax-position f) base-pos)
            'span (syntax-span f))))

;; Extract original source text for a syntax object from the file text
(define (extract-original-source stx source-text)
  (define pos (syntax-position stx))
  (define spn (syntax-span stx))
  (if (and pos spn source-text
           (<= (sub1 pos) (string-length source-text))
           (<= (+ (sub1 pos) spn) (string-length source-text)))
      (substring source-text (sub1 pos) (+ (sub1 pos) spn))
      #f))

;; ── Step serialization ───────────────────────────────────

(define (step->json s source-text)
  (define id (next-step-id!))
  (define type-sym (protostep-type s))
  (define before-stx (step-term1 s))
  (define after-stx (step-term2 s))
  (define s1 (protostep-s1 s))
  (define s2 (step-s2 s))
  (define before-pos (syntax-position before-stx))

  (hasheq 'id id
          'type (symbol->string type-sym)
          'typeLabel (step-type->string type-sym)
          'macro (step-macro-name s)
          'before (syntax->string before-stx)
          'after (syntax->string after-stx)
          'originalBefore (extract-original-source before-stx source-text)
          'beforeLoc (syntax-loc before-stx)
          'foci (serialize-foci-relative (state-foci s1) before-pos)
          'fociAfter (serialize-foci (state-foci s2))
          'seq (state-seq s1)))

;; ── Tree building from derivation ────────────────────────

;; Check if a value looks like a derivation struct (not syntax, not primitive)
(define (deriv-like? v)
  (and v (not (syntax? v)) (not (boolean? v)) (not (number? v))
       (not (string? v)) (not (void? v)) (not (symbol? v))
       (not (bytes? v)) (not (char? v)) (not (regexp? v))))

;; Walk a derivation tree and extract macro applications into a simplified tree.
;; Returns a tree node hash or #f if no macros found.
(define (deriv->tree d [depth 0])
  (cond
    [(not d) #f]
    [(> depth 50) #f]  ;; safety limit
    [(mrule? d)
     (define id (next-tree-id!))
     (define resolves (base-resolves d))
     (define macro-name
       (if (and (pair? resolves) (identifier? (car resolves)))
           (symbol->string (syntax-e (car resolves)))
           #f))
     (define before-str (syntax->string (node-z1 d)))
     (define label (if (> (string-length before-str) 50)
                       (string-append (substring before-str 0 50) "...")
                       before-str))
     ;; Recurse into the next derivation to find children
     (define child-trees (collect-child-trees (mrule-next d) (add1 depth)))
     (hasheq 'id id
             'macro macro-name
             'label label
             'children child-trees)]
    [else
     ;; For non-mrule nodes, walk struct fields generically to find nested mrules
     (define children (collect-child-trees d (add1 depth)))
     (if (null? children)
         #f
         ;; If there's exactly one child, promote it (don't wrap in anonymous node)
         (if (= (length children) 1)
             (car children)
             ;; Multiple macro children at this level — wrap in an anonymous node
             (let ([id (next-tree-id!)]
                   [before-str (if (and (node? d) (syntax? (node-z1 d)))
                                   (let ([s (syntax->string (node-z1 d))])
                                     (if (> (string-length s) 50)
                                         (string-append (substring s 0 50) "...")
                                         s))
                                   "...")])
               (hasheq 'id id
                       'macro #f
                       'label before-str
                       'children children))))]))

;; Collect all tree nodes from walking a derivation's struct fields
(define (collect-child-trees d depth)
  (cond
    [(not d) '()]
    [(> depth 50) '()]
    [(mrule? d)
     ;; This is itself a macro — make a tree node
     (define node (deriv->tree d depth))
     (if node (list node) '())]
    [else
     ;; Walk struct fields
     (with-handlers ([exn:fail? (lambda (e) '())])
       (define v (struct->vector d))
       (apply append
              (for/list ([i (in-range 1 (vector-length v))])
                (define val (vector-ref v i))
                (cond
                  [(list? val)
                   (apply append
                          (for/list ([item val])
                            (if (deriv-like? item)
                                (collect-child-trees item (add1 depth))
                                '())))]
                  [(deriv-like? val)
                   (collect-child-trees val (add1 depth))]
                  [else '()]))))]))

;; ── Public API ────────────────────────────────────────────

(define (start-macro-expander path #:macro-only? [macro-only? #f])
  (set! _macro-active #t)
  (set! _step-counter 0)
  (set! _tree-counter 0)
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

    ;; If no forms, emit empty steps and tree
    (when (null? forms)
      (send-message! (make-message "macro:steps" 'steps (list)))
      (send-message! (make-message "macro:tree" 'forms (list)))
      (cell-set! 'current-bottom-tab "macros"))

    ;; Trace each form once — collect both steps and derivations
    (unless (null? forms)
      (define trace-results
        (for/list ([form (in-list forms)])
          (with-handlers ([exn:fail? (lambda (e) (list #f #f))])
            (parameterize ([current-namespace (make-base-namespace)])
              (define-values (result deriv) (trace/result form))
              (list deriv (reductions deriv))))))

      ;; Build flat step list
      (define all-rw-steps
        (apply append
               (for/list ([tr trace-results])
                 (define red (cadr tr))
                 (if red
                     (let ([rw (filter rewrite-step? red)])
                       (if macro-only?
                           (filter (lambda (s) (eq? (protostep-type s) 'macro)) rw)
                           rw))
                     '()))))

      (define step-jsons (for/list ([s all-rw-steps]) (step->json s text)))
      (send-message! (make-message "macro:steps" 'steps step-jsons))

      ;; Build tree from derivations
      (define tree-forms
        (filter values
                (for/list ([tr trace-results])
                  (define deriv (car tr))
                  (if deriv
                      (with-handlers ([exn:fail? (lambda (e) #f)])
                        (deriv->tree deriv))
                      #f))))
      (send-message! (make-message "macro:tree" 'forms tree-forms))

      (cell-set! 'current-bottom-tab "macros"))))

(define (stop-macro-expander)
  (set! _macro-active #f)
  (cell-set! 'macro-active #f)
  (send-message! (make-message "macro:clear")))
