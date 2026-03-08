#lang racket/base

(require rackunit
         racket/port
         racket/string
         "../racket/heavymental-core/theme.rkt")

(test-case "built-in themes are registered"
  (define themes (list-themes))
  (check-not-false (member "Light" themes) "Light theme should be registered")
  (check-not-false (member "Dark" themes) "Dark theme should be registered"))

(test-case "get-theme returns theme hash"
  (define light (get-theme "Light"))
  (check-true (hash? light))
  (check-equal? (hash-ref light 'name) "Light")
  (check-equal? (hash-ref light 'bg-primary) "#FFFFFF")
  (check-equal? (hash-ref light 'monaco-theme) "vs"))

(test-case "get-theme returns #f for unknown theme"
  (check-false (get-theme "Nonexistent")))

(test-case "dark theme has correct values"
  (define dark (get-theme "Dark"))
  (check-equal? (hash-ref dark 'bg-primary) "#1E1E1E")
  (check-equal? (hash-ref dark 'fg-primary) "#D4D4D4")
  (check-equal? (hash-ref dark 'monaco-theme) "vs-dark"))

(test-case "register-theme! adds a custom theme"
  (define custom (hasheq 'name "Solarized"
                         'bg-primary "#002B36"
                         'fg-primary "#839496"))
  (register-theme! custom)
  (check-not-false (member "Solarized" (list-themes)) "Solarized should be registered")
  (check-equal? (hash-ref (get-theme "Solarized") 'bg-primary) "#002B36"))

(test-case "apply-theme! sends message for valid theme"
  (define output
    (with-output-to-string
      (lambda () (apply-theme! "Light"))))
  (check-true (string-contains? output "theme:apply")))

(test-case "apply-theme! does nothing for unknown theme"
  (define output
    (with-output-to-string
      (lambda () (apply-theme! "DoesNotExist"))))
  (check-equal? output ""))

(displayln "All theme tests passed.")
