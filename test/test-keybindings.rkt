#lang racket/base

(require rackunit
         racket/port
         racket/string
         "../racket/heavymental-core/keybindings.rkt")

(test-case "default keybindings are registered"
  (check-equal? (keybinding-ref "Cmd+S") "editor:save-request")
  (check-equal? (keybinding-ref "Cmd+R") "run")
  (check-equal? (keybinding-ref "Cmd+,") "settings:open"))

(test-case "keybinding-ref returns #f for unknown shortcut"
  (check-false (keybinding-ref "Cmd+Z+Z+Z")))

(test-case "keybinding-set! updates a binding"
  (keybinding-set! "Cmd+Shift+X" "custom-action")
  (check-equal? (keybinding-ref "Cmd+Shift+X") "custom-action")
  ;; Cleanup
  (apply-keybinding-overrides! (hasheq)))

(test-case "apply-keybinding-overrides! remaps actions"
  (apply-keybinding-overrides!
   (hasheq "run" "Cmd+Shift+R2"))
  ;; Old shortcut should no longer map to "run"
  (check-false (equal? (keybinding-ref "Cmd+R") "run"))
  ;; New shortcut should map to "run"
  (check-equal? (keybinding-ref "Cmd+Shift+R2") "run")
  ;; Reset
  (apply-keybinding-overrides! (hasheq)))

(test-case "all-keybindings returns a hash"
  (define kb (all-keybindings))
  (check-true (hash? kb))
  (check-true (> (hash-count kb) 0)))

(test-case "action-for-shortcut works"
  (check-equal? (action-for-shortcut "Cmd+R") "run"))

(test-case "send-keybindings-to-frontend! sends message"
  (define output
    (with-output-to-string
      (lambda () (send-keybindings-to-frontend!))))
  (check-true (string-contains? output "keybindings:set")))

(displayln "All keybinding tests passed.")
