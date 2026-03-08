#lang racket/base

;; Hello Component extension demonstrating define-component + ui macro.
;; Registers a custom <hm-greeting> web component and uses it in a panel.

(require heavymental/extension
         heavymental/component
         heavymental/ui
         heavymental/cell)

(define-component hm-greeting
  #:tag "hm-greeting"
  #:properties ([name "World"])
  #:template "<div class='greeting'>Hello, ${name}!</div>"
  #:style "
    :host { display: block; }
    .greeting { font-size: 18px; color: #4CAF50; padding: 8px; }
  "
  #:script "
    updated(props) {
      console.log('Greeting updated:', props.name);
    }
  ")

(define-extension hello-ext
  #:name "Hello Component"
  #:cells ([greeting-name "World"])
  #:panels ([#:id "hello" #:label "Hello" #:tab 'bottom
             #:layout (ui
                        (vbox
                          (text #:content "cell:greeting-name")))])
  #:on-activate (lambda () (register-component! hm-greeting))
  #:on-deactivate (lambda () (unregister-component! "hm-greeting")))

(provide (rename-out [hello-ext extension]))
