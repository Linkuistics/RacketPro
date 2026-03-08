#lang racket/base
(require "protocol.rkt")
(require (for-syntax racket/base))

(provide define-component
         component-descriptor?
         component-descriptor-tag
         component-descriptor-properties
         component-descriptor-template
         component-descriptor-style
         component-descriptor-script
         register-component!
         unregister-component!)

(struct component-descriptor
  (tag properties template style script)
  #:transparent)

(define-syntax (define-component stx)
  (syntax-case stx ()
    [(_ name
        #:tag tag-expr
        #:properties ([prop-name prop-default] ...)
        #:template template-expr
        #:style style-expr
        #:script script-expr)
     #'(define name
         (component-descriptor
          tag-expr
          (list (list 'prop-name prop-default) ...)
          template-expr
          style-expr
          script-expr))]))

(define (register-component! comp)
  (send-message!
    (make-message "component:register"
      'tag (component-descriptor-tag comp)
      'properties (map (lambda (p) (hasheq 'name (symbol->string (car p))
                                           'default (cadr p)))
                       (component-descriptor-properties comp))
      'template (component-descriptor-template comp)
      'style (component-descriptor-style comp)
      'script (component-descriptor-script comp))))

(define (unregister-component! tag)
  (send-message!
    (make-message "component:unregister"
      'tag tag)))
