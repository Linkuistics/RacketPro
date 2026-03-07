#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/pretty
         racket/string
         racket/struct
         syntax/modread
         macro-debugger/model/trace
         macro-debugger/model/reductions
         macro-debugger/model/steps
         macro-debugger/model/deriv
         "protocol.rkt"
         "cell.rkt"
         "pattern-extractor.rkt")

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

;; Check if a step's source location is within the user's file
;; (filters out steps from internal modules like racket/base internals)
(define (step-in-source? s source-path)
  (define before-stx (step-term1 s))
  (define src (syntax-source before-stx))
  (and src
       (or (equal? src source-path)
           (and (path? src) (path? source-path)
                (equal? (path->string src) (path->string source-path)))
           ;; Also accept string path matching
           (and (string? source-path) (path? src)
                (equal? (path->string src) source-path)))))

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

;; ── Tracing ──────────────────────────────────────────────

;; Try to read and trace as a whole module (handles #lang, user-defined macros)
;; Falls back to per-form tracing if module reading fails
(define (trace-file path text)
  (with-handlers
    ([exn:fail?
      (lambda (e)
        ;; Fallback: trace individual forms (no #lang support)
        (trace-forms-individually path text))])
    (define port (open-input-string text))
    (port-count-lines! port)
    (define module-stx
      (with-module-reading-parameterization
        (lambda () (read-syntax (string->path path) port))))
    (parameterize ([current-namespace (make-base-namespace)])
      (define-values (result deriv) (trace/result module-stx))
      (list deriv (reductions deriv)))))

;; Fallback: trace each form independently with make-base-namespace
(define (trace-forms-individually path text)
  (define port (open-input-string text))
  (port-count-lines! port)
  ;; Skip #lang line
  (with-handlers ([exn:fail? (lambda (e) (void))])
    (read-language port (lambda () #f)))
  ;; Read forms
  (define forms
    (let loop ([acc '()])
      (define stx (read-syntax path port))
      (if (eof-object? stx)
          (reverse acc)
          (loop (cons stx acc)))))
  (if (null? forms)
      (list #f #f)
      ;; Combine all derivations/reductions
      (let ([all-derivs '()]
            [all-reds '()])
        (for ([form (in-list forms)])
          (with-handlers ([exn:fail? (lambda (e) (void))])
            (parameterize ([current-namespace (make-base-namespace)])
              (define-values (result deriv) (trace/result form))
              (set! all-derivs (cons deriv all-derivs))
              (set! all-reds (append all-reds (reductions deriv))))))
        ;; Return first deriv (for tree) and combined reductions
        (list (if (null? all-derivs) #f (car (reverse all-derivs)))
              all-reds))))

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

    ;; Handle empty files
    (when (string=? (string-trim text) "")
      (send-message! (make-message "macro:steps" 'steps (list)))
      (send-message! (make-message "macro:tree" 'forms (list)))
      (cell-set! 'current-bottom-tab "macros"))

    (unless (string=? (string-trim text) "")
      ;; Trace the file — module-level or per-form fallback
      (define trace-result (trace-file path text))
      (define deriv (car trace-result))
      (define all-reds (cadr trace-result))

      (cond
        [(not all-reds)
         ;; No reductions at all
         (send-message! (make-message "macro:steps" 'steps (list)))
         (send-message! (make-message "macro:tree" 'forms (list)))]
        [else
         ;; Filter to rewrite steps, optionally source-local only
         (define rw-steps (filter rewrite-step? all-reds))
         ;; Filter to steps originating from this file (not internal modules)
         (define source-steps
           (filter (lambda (s) (step-in-source? s path)) rw-steps))
         ;; Apply macro-only filter
         (define filtered-steps
           (if macro-only?
               (filter (lambda (s) (eq? (protostep-type s) 'macro)) source-steps)
               source-steps))

         ;; Serialize and send steps
         (define step-jsons (for/list ([s filtered-steps]) (step->json s text)))
         (send-message! (make-message "macro:steps" 'steps step-jsons))

         ;; Build tree from derivation
         (define tree-forms
           (if deriv
               (let ([tree (with-handlers ([exn:fail? (lambda (e) #f)])
                             (deriv->tree deriv))])
                 (if tree (list tree) (list)))
               (list)))
         (send-message! (make-message "macro:tree" 'forms tree-forms))

         ;; Attempt pattern extraction for macro steps
         (for ([step-json (in-list step-jsons)])
           (when (string=? (hash-ref step-json 'type) "macro")
             (define macro-name (hash-ref step-json 'macro #f))
             (when macro-name
               (with-handlers ([exn:fail? (lambda (e) (void))])
                 (define pattern-info (extract-pattern macro-name path))
                 (when pattern-info
                   (send-message!
                     (make-message "macro:pattern"
                                   'stepId (hash-ref step-json 'id)
                                   'pattern (hash-ref pattern-info 'pattern)
                                   'variables (hash-ref pattern-info 'variables)
                                   'source (format "~a" path))))))))])

      (cell-set! 'current-bottom-tab "macros"))))

(define (stop-macro-expander)
  (set! _macro-active #f)
  (cell-set! 'macro-active #f)
  (send-message! (make-message "macro:clear")))
