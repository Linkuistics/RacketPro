#lang racket/base

(require racket/port
         "../racket/heavymental-core/extension.rkt"
         "../racket/heavymental-core/cell.rkt"
         "../racket/heavymental-core/protocol.rkt")

;; Simple arithmetic evaluator for the calc "language"
(define (eval-calc-expr str)
  (with-handlers ([exn:fail? (lambda (e) (format "Error: ~a" (exn-message e)))])
    (define result
      (parameterize ([current-namespace (make-base-namespace)])
        (eval (read (open-input-string str)))))
    (format "~a" result)))

(define-extension calc-lang-ext
  #:name "Calc Language"
  #:cells ([calc-output ""])
  #:panels ([#:id "calc" #:label "Calc" #:tab 'bottom
             #:layout (hasheq 'type "vbox"
                              'props (hasheq 'flex "1")
                              'children
                              (list
                               (hasheq 'type "text"
                                       'props (hasheq 'text "cell:calc-output"
                                                      'style "monospace")
                                       'children (list))))])
  #:menus ([#:menu "Racket" #:label "Eval as Calc" #:shortcut "Cmd+Shift+C"
            #:action "eval-calc"])
  #:events ([#:name "eval-calc"
             #:handler (lambda (msg)
                         (define content (hash-ref msg 'content "(+ 1 2 3)"))
                         (define result (eval-calc-expr content))
                         (cell-set! 'calc-lang-ext:calc-output result))]))

(provide (rename-out [calc-lang-ext extension]))
