#lang racket/base

(require rackunit
         racket/path
         racket/file
         "../racket/heavymental-core/project.rkt")

;; ── Test: find-project-root ─────────────────────────────────────

(test-case "find-project-root finds directory with info.rkt"
  ;; The heavymental-core directory has info.rkt
  (define core-main
    (simplify-path
     (build-path (current-directory) "racket" "heavymental-core" "main.rkt")))
  (when (file-exists? core-main)
    (define root (find-project-root (path->string core-main)))
    (check-true (file-exists? (build-path root "info.rkt")))))

(test-case "find-project-root falls back to parent dir"
  (define tmp (make-temporary-file "project-test-~a" 'directory))
  (define file (build-path tmp "test.rkt"))
  (with-output-to-file file (lambda () (display "")))
  (define root (find-project-root (path->string file)))
  (check-equal? root (path->string tmp))
  (delete-file file)
  (delete-directory tmp))

;; ── Test: project-collection-name ───────────────────────────────

(test-case "project-collection-name returns dir name when no info.rkt"
  (define tmp (make-temporary-file "my-project-~a" 'directory))
  (define name (project-collection-name (path->string tmp)))
  (check-true (string? name))
  (check-true (> (string-length name) 0))
  (delete-directory tmp))

;; ── Test: read-info-rkt ─────────────────────────────────────────

(test-case "read-info-rkt returns empty hash for missing file"
  (define result (read-info-rkt "/tmp/nonexistent-12345"))
  (check-true (hash? result))
  (check-equal? (hash-count result) 0))

(displayln "All project tests passed.")
