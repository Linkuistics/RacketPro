#lang racket/base

(require rackunit
         json
         racket/port
         racket/string
         racket/list
         "../racket/heavymental-core/protocol.rkt"
         "../racket/heavymental-core/cell.rkt"
         "../racket/heavymental-core/extension.rkt")

;; ── Helpers ──────────────────────────────────────────────────────────────────

(define (parse-all-messages output)
  (define lines (string-split (string-trim output) "\n"))
  (for/list ([line (in-list lines)]
             #:when (> (string-length (string-trim line)) 0))
    (string->jsexpr line)))

(define (find-message-by-type msgs type)
  (findf (lambda (m) (string=? (hash-ref m 'type "") type)) msgs))

(define (find-all-messages-by-type msgs type)
  (filter (lambda (m) (string=? (hash-ref m 'type "") type)) msgs))

;; ── Test: define-extension creates a valid descriptor ────────────────────────

(test-case "define-extension creates extension-descriptor struct"
  (define-extension test-ext
    #:name "Test Extension"
    #:cells ([counter 0] [label "hello"])
    #:events ([#:name "increment"
               #:handler (lambda (msg) (void))]))
  (check-true (extension-descriptor? test-ext))
  (check-equal? (extension-descriptor-id test-ext) 'test-ext)
  (check-equal? (extension-descriptor-name test-ext) "Test Extension"))

(test-case "define-extension captures cells with names and initial values"
  (define-extension cell-test
    #:name "Cell Test"
    #:cells ([count 0] [name "world"]))
  (define cells (extension-descriptor-cells cell-test))
  (check-equal? (length cells) 2)
  ;; Each cell is (cons 'name initial-value)
  (check-equal? (car (first cells)) 'count)
  (check-equal? (cdr (first cells)) 0)
  (check-equal? (car (second cells)) 'name)
  (check-equal? (cdr (second cells)) "world"))

(test-case "define-extension captures events with names and handlers"
  (define handler-called #f)
  (define-extension event-test
    #:name "Event Test"
    #:events ([#:name "do-thing"
               #:handler (lambda (msg) (set! handler-called #t))]))
  (define events (extension-descriptor-events event-test))
  (check-equal? (length events) 1)
  (check-equal? (hash-ref (first events) 'name) "do-thing")
  ;; Call the handler to verify it works
  ((hash-ref (first events) 'handler) (hasheq))
  (check-true handler-called))

(test-case "define-extension captures panels"
  (define-extension panel-test
    #:name "Panel Test"
    #:panels ([#:id "my-panel" #:label "My Panel" #:tab 'bottom
               #:layout (hasheq 'type "vbox"
                                'props (hasheq)
                                'children (list))]))
  (define panels (extension-descriptor-panels panel-test))
  (check-equal? (length panels) 1)
  (check-equal? (hash-ref (first panels) 'id) "my-panel")
  (check-equal? (hash-ref (first panels) 'label) "My Panel")
  (check-equal? (hash-ref (first panels) 'tab) 'bottom))

(test-case "define-extension captures menus"
  (define-extension menu-test
    #:name "Menu Test"
    #:menus ([#:menu "Tools" #:label "My Tool" #:shortcut "Cmd+Shift+T"
              #:action "run-tool"]))
  (define menus (extension-descriptor-menus menu-test))
  (check-equal? (length menus) 1)
  (check-equal? (hash-ref (first menus) 'menu) "Tools")
  (check-equal? (hash-ref (first menus) 'label) "My Tool")
  (check-equal? (hash-ref (first menus) 'action) "run-tool"))

(test-case "define-extension captures lifecycle hooks"
  (define activated #f)
  (define deactivated #f)
  (define-extension lifecycle-test
    #:name "Lifecycle Test"
    #:on-activate (lambda () (set! activated #t))
    #:on-deactivate (lambda () (set! deactivated #t)))
  ;; Hooks are stored as thunks
  (check-true (procedure? (extension-descriptor-on-activate lifecycle-test)))
  ((extension-descriptor-on-activate lifecycle-test))
  (check-true activated)
  ((extension-descriptor-on-deactivate lifecycle-test))
  (check-true deactivated))

(test-case "define-extension with only required fields"
  (define-extension minimal-ext
    #:name "Minimal")
  (check-true (extension-descriptor? minimal-ext))
  (check-equal? (extension-descriptor-cells minimal-ext) '())
  (check-equal? (extension-descriptor-panels minimal-ext) '())
  (check-equal? (extension-descriptor-events minimal-ext) '())
  (check-equal? (extension-descriptor-menus minimal-ext) '())
  (check-false (extension-descriptor-on-activate minimal-ext))
  (check-false (extension-descriptor-on-deactivate minimal-ext)))
