#lang racket/base
(require (for-syntax racket/base racket/list))
(provide ui)

;; The `ui` macro transforms declarative layout expressions into hasheq trees.
;;
;; Usage:
;;   (ui (vbox (text #:content "hello")))
;;   =>
;;   (hasheq 'type "hm-vbox"
;;           'props (hasheq)
;;           'children (list (hasheq 'type "hm-text"
;;                                   'props (hasheq 'content "hello")
;;                                   'children (list))))
;;
;; Features:
;; - Auto-prefixes "hm-" to element type names
;; - Keyword args become props: #:key val => 'key val
;; - Non-keyword args are children, recursively processed
;; - Unquote (,expr) splices pre-built nodes

(define-syntax (ui stx)
  (syntax-case stx (unquote)
    [(_ (unquote expr))
     #'expr]
    [(_ (elem-type args ...))
     #'(ui-node elem-type args ...)]))

(define-syntax (ui-node stx)
  (syntax-case stx ()
    [(_ elem-type args ...)
     (let ()
       (define args-list (syntax->list #'(args ...)))
       ;; Split args into keyword props and children
       (define-values (prop-pairs children)
         (let loop ([remaining args-list] [props-acc '()] [children-acc '()])
           (cond
             [(null? remaining)
              (values (reverse props-acc) (reverse children-acc))]
             ;; keyword arg: #:key val
             [(keyword? (syntax-e (car remaining)))
              (when (null? (cdr remaining))
                (raise-syntax-error 'ui "keyword missing value" (car remaining)))
              (loop (cddr remaining)
                    (cons (list (car remaining) (cadr remaining)) props-acc)
                    children-acc)]
             ;; child expression
             [else
              (loop (cdr remaining)
                    props-acc
                    (cons (car remaining) children-acc))])))
       ;; Build the type string
       (define type-str
         (string-append "hm-" (symbol->string (syntax-e #'elem-type))))
       ;; Build props hasheq: alternating 'key val pairs
       ;; Each prop-pair is (list #:key-stx val-stx)
       ;; We need to produce (hasheq 'key1 val1 'key2 val2 ...)
       (define prop-kv-stxs
         (apply append
                (map (lambda (p)
                       (define kw (syntax-e (car p)))  ; a keyword
                       (define key-sym (string->symbol (keyword->string kw)))
                       (define key-stx (datum->syntax stx `(quote ,key-sym)))
                       (list key-stx (cadr p)))
                     prop-pairs)))
       ;; Build children expressions - recursively process nested forms
       (define children-exprs
         (map (lambda (child)
                (syntax-case child (unquote)
                  [(unquote expr) #'expr]
                  [(child-type child-args ...)
                   #'(ui-node child-type child-args ...)]
                  [expr #'expr]))
              children))
       (with-syntax ([type-s type-str]
                     [(pkv ...) prop-kv-stxs]
                     [(child-e ...) children-exprs])
         #'(hasheq 'type type-s
                   'props (hasheq pkv ...)
                   'children (list child-e ...))))]))
