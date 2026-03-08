#lang racket/base

(require racket/list "protocol.rkt")

(provide default-keybindings
         keybinding-ref
         keybinding-set!
         all-keybindings
         apply-keybinding-overrides!
         send-keybindings-to-frontend!
         action-for-shortcut)

;; Default keybindings: shortcut → action
(define default-keybindings
  (hasheq "Cmd+N" "new-file"
          "Cmd+O" "open-file"
          "Cmd+S" "editor:save-request"
          "Cmd+R" "run"
          "Cmd+," "settings:open"
          "Cmd+Shift+F" "find-in-project"
          "Cmd+Shift+R" "step-through"
          "Cmd+Shift+E" "expand-macros"))

;; Active keybindings (defaults + overrides)
(define _keybindings (make-hash))

;; Initialize with defaults
(for ([(k v) (in-hash default-keybindings)])
  (hash-set! _keybindings k v))

;; Get action for a shortcut
(define (keybinding-ref shortcut)
  (hash-ref _keybindings shortcut #f))

;; Set a keybinding (shortcut → action)
(define (keybinding-set! shortcut action)
  (hash-set! _keybindings shortcut action))

;; Get all active keybindings as an immutable hash.
;; Keys are converted to symbols for JSON serialization compatibility.
(define (all-keybindings)
  (for/hasheq ([(k v) (in-hash _keybindings)])
    (values (string->symbol k) v)))

;; Look up action by shortcut
(define (action-for-shortcut shortcut)
  (hash-ref _keybindings shortcut #f))

;; Apply user overrides from settings.
;; overrides is a hasheq of action → shortcut (reversed mapping).
(define (apply-keybinding-overrides! overrides)
  ;; Reset to defaults first
  (hash-clear! _keybindings)
  (for ([(k v) (in-hash default-keybindings)])
    (hash-set! _keybindings k v))
  ;; Apply overrides: remove old shortcut for action, add new one
  (for ([(action new-shortcut) (in-hash overrides)])
    ;; Remove any existing binding for this action
    (for ([(shortcut act) (in-hash _keybindings)])
      (when (equal? act action)
        (hash-remove! _keybindings shortcut)))
    ;; Add the new binding
    (hash-set! _keybindings new-shortcut action)))

;; Send the active keymap to the frontend
(define (send-keybindings-to-frontend!)
  (send-message! (make-message "keybindings:set"
                               'keybindings (all-keybindings))))
