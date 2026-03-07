#lang racket/base

(require racket/list
         racket/string
         "protocol.rkt"
         "cell.rkt")

(provide define-extension
         extension-descriptor
         extension-descriptor?
         extension-descriptor-id
         extension-descriptor-name
         extension-descriptor-cells
         extension-descriptor-panels
         extension-descriptor-events
         extension-descriptor-menus
         extension-descriptor-on-activate
         extension-descriptor-on-deactivate)

;; ── Descriptor struct ────────────────────────────────────────────────────────

(struct extension-descriptor
  (id name cells panels events menus on-activate on-deactivate)
  #:transparent)

;; ── define-extension macro ───────────────────────────────────────────────────
;;
;; Usage:
;;   (define-extension ext-id
;;     #:name "Human Name"
;;     #:cells ([cell-name initial-value] ...)
;;     #:panels ([#:id "id" #:label "Label" #:tab 'bottom #:layout expr] ...)
;;     #:events ([#:name "name" #:handler proc] ...)
;;     #:menus ([#:menu "Menu" #:label "Label" #:shortcut "Cmd+X" #:action "act"] ...)
;;     #:on-activate thunk
;;     #:on-deactivate thunk)
;;
;; All clauses except #:name are optional.
;; Clauses can appear in any order after #:name.

(define-syntax define-extension
  (syntax-rules ()
    [(_ ext-id #:name name-val rest ...)
     (define ext-id
       (build-extension-descriptor/accum
        ext-id name-val
        (list) (list) (list) (list) #f #f
        rest ...))]))

;; Accumulator macro that processes remaining keyword arguments.
;;
;; Pattern variables use _ext- prefix to avoid shadowing template symbols.
;; In syntax-rules, (quote x) in the template quotes the binding of
;; pattern variable x, NOT the literal symbol x. So accumulator variable
;; names must not collide with hash key names used in templates.
(define-syntax build-extension-descriptor/accum
  (syntax-rules ()
    ;; Done -- no more clauses, build the struct
    [(_ _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
        _ext-activate _ext-deactivate)
     (extension-descriptor '_ext-id _ext-name
                           _ext-cells _ext-panels _ext-events _ext-menus
                           _ext-activate _ext-deactivate)]

    ;; #:cells ([name val] ...)
    [(_ _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
        _ext-activate _ext-deactivate
        #:cells ([cell-name cell-val] ...) rest ...)
     (build-extension-descriptor/accum
      _ext-id _ext-name
      (list (cons 'cell-name cell-val) ...)
      _ext-panels _ext-events _ext-menus _ext-activate _ext-deactivate
      rest ...)]

    ;; #:panels ([#:id pid #:label plabel #:tab ptab #:layout playout] ...)
    [(_ _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
        _ext-activate _ext-deactivate
        #:panels ([#:id pid #:label plabel #:tab ptab #:layout playout] ...) rest ...)
     (build-extension-descriptor/accum
      _ext-id _ext-name _ext-cells
      (list (hasheq 'id pid 'label plabel 'tab ptab 'layout playout) ...)
      _ext-events _ext-menus _ext-activate _ext-deactivate
      rest ...)]

    ;; #:events ([#:name ename #:handler ehandler] ...)
    [(_ _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
        _ext-activate _ext-deactivate
        #:events ([#:name ename #:handler ehandler] ...) rest ...)
     (build-extension-descriptor/accum
      _ext-id _ext-name _ext-cells _ext-panels
      (list (hasheq 'name ename 'handler ehandler) ...)
      _ext-menus _ext-activate _ext-deactivate
      rest ...)]

    ;; #:menus ([#:menu mmenu #:label mlabel #:shortcut mshortcut #:action maction] ...)
    [(_ _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
        _ext-activate _ext-deactivate
        #:menus ([#:menu mmenu #:label mlabel #:shortcut mshortcut #:action maction] ...) rest ...)
     (build-extension-descriptor/accum
      _ext-id _ext-name _ext-cells _ext-panels _ext-events
      (list (hasheq 'menu mmenu 'label mlabel 'shortcut mshortcut 'action maction) ...)
      _ext-activate _ext-deactivate
      rest ...)]

    ;; #:on-activate thunk
    [(_ _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
        _ext-activate _ext-deactivate
        #:on-activate new-activate rest ...)
     (build-extension-descriptor/accum
      _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
      new-activate _ext-deactivate
      rest ...)]

    ;; #:on-deactivate thunk
    [(_ _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
        _ext-activate _ext-deactivate
        #:on-deactivate new-deactivate rest ...)
     (build-extension-descriptor/accum
      _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
      _ext-activate new-deactivate
      rest ...)]))
