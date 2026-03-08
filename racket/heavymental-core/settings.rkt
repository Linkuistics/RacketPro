#lang racket/base

(require json racket/path "protocol.rkt")

(provide current-settings
         settings-ref
         settings-set!
         apply-loaded-settings!
         save-settings!
         load-project-settings!)

;; Internal settings hash — merged from defaults + global + project
(define _settings (make-hasheq))

;; Default settings
(define _defaults
  (hasheq 'theme "Light"
          'editor (hasheq 'fontFamily "SF Mono"
                          'fontSize 13
                          'fontWeight 300
                          'vimMode #f
                          'tabSize 2
                          'wordWrap #f
                          'minimap #f
                          'lineNumbers #t)
          'keybindings (hasheq)
          'window (hasheq 'width 1200 'height 800)
          'recentFiles '()))

;; Get the full settings hash
(define (current-settings)
  _settings)

;; Get a top-level setting by key symbol
(define (settings-ref key [default #f])
  (hash-ref _settings key default))

;; Set a top-level setting and trigger save
(define (settings-set! key value)
  (hash-set! _settings key value)
  (save-settings!))

;; Deep-merge: overlay wins over base for each key.
;; Both should be hasheqs.
(define (deep-merge base overlay)
  (define result (hash-copy base))
  (for ([(k v) (in-hash overlay)])
    (cond
      [(and (hash? v) (hash? (hash-ref result k #f)))
       (hash-set! result k (deep-merge (hash-ref result k) v))]
      [else
       (hash-set! result k v)]))
  result)

;; Apply settings received from Rust (settings:loaded message).
;; Merges defaults with loaded settings.
(define (apply-loaded-settings! loaded-hash)
  (set! _settings (deep-merge (hash-copy _defaults) loaded-hash)))

;; Send current settings to Rust for persistence
(define (save-settings!)
  (send-message! (make-message "settings:save"
                               'settings _settings)))

;; Load per-project settings from .heavymental/settings.rkt
;; Returns a hasheq or empty hasheq if file doesn't exist.
(define (load-project-settings! project-root)
  (define settings-path
    (build-path project-root ".heavymental" "settings.rkt"))
  (cond
    [(file-exists? settings-path)
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (eprintf "Error loading project settings: ~a\n"
                                 (exn-message e))
                        (hasheq))])
       (dynamic-require settings-path 'project-settings))]
    [else (hasheq)]))
