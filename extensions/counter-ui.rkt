#lang racket/base

;; Counter extension rewritten using the ui macro instead of raw hasheq trees.
;; Demonstrates inline lambda handlers via handler auto-registration.

(require heavymental/extension
         heavymental/ui
         heavymental/cell)

(define-extension counter-ui-ext
  #:name "Counter (UI DSL)"
  #:cells ([count 0])
  #:panels ([#:id "counter-ui" #:label "Counter UI" #:tab 'bottom
             #:layout (ui
                        (vbox
                          (text #:content "cell:count")
                          (hbox
                            (button #:label "+1"
                                    #:on-click (lambda ()
                                                 (cell-update! 'counter-ui-ext:count add1)))
                            (button #:label "Reset"
                                    #:on-click (lambda ()
                                                 (cell-set! 'counter-ui-ext:count 0))))))])
  #:events ())

(provide (rename-out [counter-ui-ext extension]))
