#lang racket/base

(require "protocol.rkt")

(provide define-cell
         make-cell
         cell-ref
         cell-set!
         cell-update!
         cell-unregister!
         all-cells
         register-all-cells!)

;; Internal cell storage
(define cells (make-hasheq))

;; Create a named cell with an initial value
(define (make-cell name initial-value)
  (hash-set! cells name initial-value))

;; Macro: (define-cell counter 0)
(define-syntax-rule (define-cell name initial-value)
  (make-cell 'name initial-value))

;; Get current value by name symbol
(define (cell-ref name)
  (hash-ref cells name
             (lambda ()
               (error 'cell-ref "unknown cell: ~a" name))))

;; Set value and send "cell:update" message to frontend
(define (cell-set! name value)
  (hash-set! cells name value)
  (send-message! (make-message "cell:update"
                               'name (symbol->string name)
                               'value value)))

;; Update with a function: (cell-update! 'counter add1)
(define (cell-update! name fn)
  (cell-set! name (fn (cell-ref name))))

;; Remove a cell and notify the frontend
(define (cell-unregister! name)
  (hash-remove! cells name)
  (send-message! (make-message "cell:unregister"
                               'name (symbol->string name))))

;; Return the internal hash
(define (all-cells)
  cells)

;; Send "cell:register" for every cell
(define (register-all-cells!)
  (for ([(name value) (in-hash cells)])
    (send-message! (make-message "cell:register"
                                 'name (symbol->string name)
                                 'value value))))
