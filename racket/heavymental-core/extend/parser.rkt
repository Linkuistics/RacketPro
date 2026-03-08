#lang racket/base
(require racket/match)
(provide parse-extend-source)

;; Parse a list of extend-lang declarations into a hash table.
;;
;; Supported declaration forms:
;;   (name: "Human Name")
;;   (cell name = initial-value)
;;   (panel id "Label" tab layout-expr)
;;   (event name handler-body)
;;   (menu "Menu" "Label" "Shortcut" action-symbol)
;;   (on-activate body)
;;   (on-deactivate body)
;;
;; Returns a mutable hash with keys:
;;   'name, 'cells, 'panels, 'events, 'menus, 'on-activate, 'on-deactivate

(define (parse-extend-source decls)
  (define result (make-hash))
  (hash-set! result 'name #f)
  (hash-set! result 'cells '())
  (hash-set! result 'panels '())
  (hash-set! result 'events '())
  (hash-set! result 'menus '())
  (hash-set! result 'on-activate #f)
  (hash-set! result 'on-deactivate #f)

  (for ([decl (in-list decls)])
    (match (car decl)
      ['name: (hash-set! result 'name (cadr decl))]
      ['cell
       (hash-update! result 'cells
         (lambda (cs)
           (cons (list (list-ref decl 1) (list-ref decl 3)) cs)))]
      ['panel
       (hash-update! result 'panels
         (lambda (ps)
           (cons (list (list-ref decl 1)   ;; id
                       (list-ref decl 2)   ;; label
                       (list-ref decl 3)   ;; tab
                       (list-ref decl 4))  ;; layout
                 ps)))]
      ['event
       (hash-update! result 'events
         (lambda (es)
           (cons (list (list-ref decl 1)   ;; name
                       (list-ref decl 2))  ;; handler body
                 es)))]
      ['menu
       (hash-update! result 'menus
         (lambda (ms)
           (cons (list (list-ref decl 1)   ;; menu
                       (list-ref decl 2)   ;; label
                       (list-ref decl 3)   ;; shortcut
                       (list-ref decl 4))  ;; action
                 ms)))]
      ['on-activate
       (hash-set! result 'on-activate (cadr decl))]
      ['on-deactivate
       (hash-set! result 'on-deactivate (cadr decl))]))

  ;; Reverse lists to maintain declaration order
  (hash-update! result 'cells reverse)
  (hash-update! result 'panels reverse)
  (hash-update! result 'events reverse)
  (hash-update! result 'menus reverse)
  result)
