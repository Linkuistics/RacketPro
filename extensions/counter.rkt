#lang racket/base

(require "../racket/heavymental-core/extension.rkt"
         "../racket/heavymental-core/cell.rkt")

(define-extension counter-ext
  #:name "Counter"
  #:cells ([count 0])
  #:panels ([#:id "counter" #:label "Counter" #:tab 'bottom
             #:layout (hasheq 'type "vbox"
                              'props (hasheq 'flex "1")
                              'children
                              (list
                               (hasheq 'type "text"
                                       'props (hasheq 'text "cell:count")
                                       'children (list))
                               (hasheq 'type "button"
                                       'props (hasheq 'label "+1"
                                                      'on-click "increment")
                                       'children (list))))])
  #:events ([#:name "increment"
             #:handler (lambda (msg)
                         (cell-update! 'counter-ext:count add1))]))

(provide (rename-out [counter-ext extension]))
