#lang racket/base

(require rackunit
         json
         racket/port
         "../racket/heavymental-core/settings.rkt")

;; ── Test: default settings ──────────────────────────────────────────

(test-case "current-settings returns a hash"
  (check-true (hash? (current-settings))))

(test-case "settings-ref returns default values"
  (apply-loaded-settings! (hasheq))
  (check-equal? (settings-ref 'theme) "Light")
  (check-true (hash? (settings-ref 'editor))))

;; ── Test: apply-loaded-settings! merges correctly ───────────────────

(test-case "apply-loaded-settings! merges with defaults"
  (apply-loaded-settings! (hasheq 'theme "Dark"))
  (check-equal? (settings-ref 'theme) "Dark")
  ;; Editor defaults should still be present
  (check-equal? (hash-ref (settings-ref 'editor) 'fontSize) 13))

(test-case "apply-loaded-settings! deep-merges nested hashes"
  (apply-loaded-settings!
   (hasheq 'editor (hasheq 'fontSize 16)))
  ;; fontSize overridden
  (check-equal? (hash-ref (settings-ref 'editor) 'fontSize) 16)
  ;; fontFamily preserved from defaults
  (check-equal? (hash-ref (settings-ref 'editor) 'fontFamily) "SF Mono"))

;; ── Test: settings-set! updates value ───────────────────────────────

(test-case "settings-set! updates a top-level key"
  (apply-loaded-settings! (hasheq))
  ;; Capture messages to avoid sending to stdout
  (parameterize ([current-output-port (open-output-nowhere)])
    (settings-set! 'theme "Solarized"))
  (check-equal? (settings-ref 'theme) "Solarized"))

;; ── Test: load-project-settings! with missing file ──────────────────

(test-case "load-project-settings! returns empty hash for missing file"
  (define result (load-project-settings! "/tmp/nonexistent-project-12345"))
  (check-true (hash? result))
  (check-equal? (hash-count result) 0))

(displayln "All settings tests passed.")
