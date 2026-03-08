#lang racket/base

(require racket/path racket/list racket/string)

(provide find-project-root
         read-info-rkt
         project-collection-name)

;; Normalize a directory path string: remove trailing slash if present
;; (unless it's the root "/").
(define (normalize-dir-string s)
  (if (and (> (string-length s) 1) (string-suffix? s "/"))
      (substring s 0 (sub1 (string-length s)))
      s))

;; Walk up from `start-path` looking for a directory containing `info.rkt`.
;; Returns the directory path string if found, or the parent of start-path.
(define (find-project-root start-path)
  (define start (if (file-exists? start-path)
                    (path-only start-path)
                    (string->path start-path)))
  (let loop ([dir (simplify-path start)])
    (define info (build-path dir "info.rkt"))
    (cond
      [(file-exists? info) (normalize-dir-string (path->string dir))]
      [else
       (define parent (simplify-path (build-path dir 'up)))
       (cond
         [(equal? dir parent)
          ;; Reached filesystem root — fall back to start dir
          (normalize-dir-string (path->string start))]
         [else (loop parent)])])))

;; Read info.rkt and extract metadata.
;; Returns a hasheq with 'collection, 'deps, etc. or empty hasheq on error.
(define (read-info-rkt project-root)
  (define info-path (build-path project-root "info.rkt"))
  (cond
    [(file-exists? info-path)
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (eprintf "Error reading info.rkt: ~a\n" (exn-message e))
                        (hasheq))])
       (define ns (make-base-namespace))
       (define info-mod (dynamic-require info-path #f))
       (define collection
         (with-handlers ([exn:fail? (lambda (e) #f)])
           (dynamic-require info-path 'collection)))
       (define deps
         (with-handlers ([exn:fail? (lambda (e) '())])
           (dynamic-require info-path 'deps)))
       (hasheq 'collection (or collection "")
               'deps (if (list? deps) deps '())))]
    [else (hasheq)]))

;; Get the collection name for display purposes.
(define (project-collection-name project-root)
  (define info (read-info-rkt project-root))
  (define coll (hash-ref info 'collection ""))
  (if (string=? coll "")
      (let-values ([(base name dir?) (split-path (string->path project-root))])
        (path->string name))
      coll))
