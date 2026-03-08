#lang racket/base
(require racket/string
         syntax/strip-context)
(provide (rename-out [extend-read read]
                     [extend-read-syntax read-syntax]))

;; ── #lang heavymental/extend reader ─────────────────────────────────────────
;;
;; Parses a simplified surface syntax into a module that provides
;; an extension-descriptor as `extension`.
;;
;; Input:
;;   #lang heavymental/extend
;;   (name: "Counter")
;;   (cell count = 0)
;;   (event increment (cell-update! 'count add1))
;;
;; Output (approximately):
;;   (module counter racket/base
;;     (require heavymental/extension heavymental/cell heavymental/ui)
;;     (define extension
;;       (extension-descriptor 'counter "Counter" ...))
;;     (provide extension))

(define (extend-read in)
  (syntax->datum (extend-read-syntax #f in)))

(define (extend-read-syntax src in)
  (define decls (read-all-decls in))
  (define ext-name (find-name decls))
  (define ext-id (name->id ext-name))
  (strip-context
   #`(module #,ext-id racket/base
       (require heavymental/extension
                heavymental/cell
                heavymental/ui)
       (define extension
         #,(generate-descriptor ext-id ext-name decls))
       (provide extension))))

;; ── Helpers ─────────────────────────────────────────────────────────────────

;; Read all S-expression forms from the port
(define (read-all-decls in)
  (let loop ([acc '()])
    (define form (read in))
    (if (eof-object? form)
        (reverse acc)
        (loop (cons form acc)))))

;; Extract the name from declarations, or use a default
(define (find-name decls)
  (for/or ([d (in-list decls)])
    (and (pair? d) (eq? (car d) 'name:) (cadr d))))

;; Convert "Test Extension" -> test-extension (symbol)
(define (name->id name)
  (if name
      (string->symbol
       (string-downcase
        (string-replace (string-trim name) " " "-")))
      'extension))

;; Generate the (extension-descriptor ...) form from parsed declarations
(define (generate-descriptor ext-id ext-name decls)
  (define cells '())
  (define panels '())
  (define events '())
  (define menus '())
  (define on-activate #f)
  (define on-deactivate #f)

  (for ([d (in-list decls)])
    (when (pair? d)
      (case (car d)
        [(cell)
         ;; (cell name = val)
         (set! cells (cons (list (list-ref d 1) (list-ref d 3)) cells))]
        [(panel)
         ;; (panel id "Label" tab layout-expr)
         (set! panels
               (cons (list (list-ref d 1)
                           (list-ref d 2)
                           (list-ref d 3)
                           (list-ref d 4))
                     panels))]
        [(event)
         ;; (event name handler-body)
         (set! events (cons (list (list-ref d 1) (list-ref d 2)) events))]
        [(menu)
         ;; (menu "Menu" "Label" "Shortcut" action)
         (set! menus
               (cons (list (list-ref d 1) (list-ref d 2)
                           (list-ref d 3) (list-ref d 4))
                     menus))]
        [(on-activate)
         (set! on-activate (cadr d))]
        [(on-deactivate)
         (set! on-deactivate (cadr d))])))

  ;; Reverse to maintain declaration order
  (set! cells (reverse cells))
  (set! panels (reverse panels))
  (set! events (reverse events))
  (set! menus (reverse menus))

  ;; Build cells list: (list (cons 'name val) ...)
  (define cells-expr
    `(list ,@(for/list ([c (in-list cells)])
               `(cons ',(car c) ,(cadr c)))))

  ;; Build panels list: (list (hasheq 'id "id" 'label "Label" 'tab 'tab 'layout layout) ...)
  (define panels-expr
    `(list ,@(for/list ([p (in-list panels)])
               `(hasheq 'id ,(symbol->string (list-ref p 0))
                        'label ,(list-ref p 1)
                        'tab ',(list-ref p 2)
                        'layout (ui ,(list-ref p 3))))))

  ;; Build events list: (list (hasheq 'name "name" 'handler (lambda (msg) body)) ...)
  (define events-expr
    `(list ,@(for/list ([e (in-list events)])
               `(hasheq 'name ,(symbol->string (car e))
                        'handler (lambda (msg) ,(cadr e))))))

  ;; Build menus list: (list (hasheq 'menu m 'label l 'shortcut s 'action a) ...)
  (define menus-expr
    `(list ,@(for/list ([m (in-list menus)])
               `(hasheq 'menu ,(list-ref m 0)
                        'label ,(list-ref m 1)
                        'shortcut ,(list-ref m 2)
                        'action ,(symbol->string (list-ref m 3))))))

  ;; Build the extension-descriptor form
  `(extension-descriptor
    ',ext-id
    ,ext-name
    ,cells-expr
    ,panels-expr
    ,events-expr
    ,menus-expr
    ,(if on-activate `(lambda () ,on-activate) #f)
    ,(if on-deactivate `(lambda () ,on-deactivate) #f)))
