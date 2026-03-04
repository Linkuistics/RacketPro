#lang racket/base

(require json racket/port racket/string)

(provide send-message!
         read-message
         make-message
         message-type
         message-ref
         start-message-loop)

;; Write a JSON object as one line to stdout and flush
(define (send-message! msg)
  (write-json msg (current-output-port))
  (newline (current-output-port))
  (flush-output (current-output-port)))

;; Read one line from stdin and parse as JSON.
;; Returns eof on eof, #f on empty/invalid lines.
(define (read-message)
  (define line (read-line (current-input-port)))
  (cond
    [(eof-object? line) eof]
    [(string=? (string-trim line) "") #f]
    [else
     (with-handlers ([exn:fail? (lambda (e) #f)])
       (string->jsexpr line))]))

;; Construct a hasheq with 'type and additional key-value pairs.
;; Usage: (make-message "cell:update" 'name "counter" 'value 42)
(define (make-message type . kvs)
  (define h (make-hasheq))
  (hash-set! h 'type type)
  (let loop ([pairs kvs])
    (cond
      [(null? pairs) h]
      [(null? (cdr pairs))
       (error 'make-message "odd number of key-value arguments")]
      [else
       (hash-set! h (car pairs) (cadr pairs))
       (loop (cddr pairs))])))

;; Extract the 'type field from a message
(define (message-type msg)
  (hash-ref msg 'type #f))

;; Extract a field with optional default
(define (message-ref msg key [default #f])
  (hash-ref msg key default))

;; Read messages in a loop, call handler for each valid message.
;; Handles errors gracefully.
(define (start-message-loop handler)
  (let loop ()
    (define msg (read-message))
    (cond
      [(eof-object? msg) (void)]
      [(not msg) (loop)]
      [else
       (with-handlers ([exn:fail?
                        (lambda (e)
                          (eprintf "Error handling message: ~a\n"
                                   (exn-message e)))])
         (handler msg))
       (loop)])))
