#lang racket/base
(require rackunit
         racket/list
         racket/port
         json
         "../racket/heavymental-core/component.rkt"
         "../racket/heavymental-core/protocol.rkt"
         "../racket/heavymental-core/ui.rkt")

;; Helper: parse JSON messages from captured output
(define (parse-all-messages str)
  (with-input-from-string str
    (lambda ()
      (let loop ([msgs '()])
        (define line (read-line))
        (if (eof-object? line)
            (reverse msgs)
            (with-handlers ([exn:fail? (lambda (e) (loop msgs))])
              (loop (cons (string->jsexpr line) msgs))))))))

(define (find-message-by-type msgs type)
  (for/or ([m (in-list msgs)])
    (and (hash? m) (equal? (hash-ref m 'type #f) type) m)))

;; Test: define-component creates a descriptor
(test-case "define-component creates component descriptor"
  (define-component test-comp
    #:tag "hm-test-comp"
    #:properties ([value "default"])
    #:template "<div>${value}</div>"
    #:style ":host { display: block; }"
    #:script "updated(props) {}")
  (check-true (component-descriptor? test-comp))
  (check-equal? (component-descriptor-tag test-comp) "hm-test-comp")
  (check-equal? (length (component-descriptor-properties test-comp)) 1))

;; Test: register-component! sends message
(test-case "register-component! sends component:register message"
  (define-component reg-comp
    #:tag "hm-reg-comp"
    #:properties ([data '()])
    #:template "<span>test</span>"
    #:style ""
    #:script "")
  (define output
    (with-output-to-string
      (lambda ()
        (register-component! reg-comp))))
  (define msgs (parse-all-messages output))
  (define reg-msg (find-message-by-type msgs "component:register"))
  (check-true (hash? reg-msg))
  (check-equal? (hash-ref reg-msg 'tag) "hm-reg-comp"))

;; Test: unregister-component! sends message
(test-case "unregister-component! sends component:unregister message"
  (define output
    (with-output-to-string
      (lambda ()
        (unregister-component! "hm-reg-comp"))))
  (define msgs (parse-all-messages output))
  (define unreg-msg (find-message-by-type msgs "component:unregister"))
  (check-true (hash? unreg-msg))
  (check-equal? (hash-ref unreg-msg 'tag) "hm-reg-comp"))

;; Test: template can be a layout tree (from ui macro)
(test-case "define-component with layout tree template"
  (define-component tree-comp
    #:tag "hm-tree-comp"
    #:properties ([height 32])
    #:template (ui (vbox (text #:content "hello")))
    #:style ""
    #:script "")
  (check-true (hash? (component-descriptor-template tree-comp))))
