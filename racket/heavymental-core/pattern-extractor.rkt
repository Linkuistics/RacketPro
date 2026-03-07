#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/port
         racket/string)

(provide extract-pattern)

;; extract-pattern: Given a macro name and a file path, try to find
;; the macro's definition and extract its syntax-parse pattern.
;;
;; Returns: hasheq with 'pattern (string) and 'variables (list of hasheq)
;;          or #f if not found.
(define (extract-pattern macro-name file-path)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (unless (and (string? file-path) (file-exists? file-path))
      (error "file not found"))

    (define text (file->string file-path))
    ;; Strip #lang line and any #reader lines before reading S-expressions
    (define stripped (strip-lang-lines text))
    (define port (open-input-string stripped))

    ;; Read all S-expressions, looking for the macro definition
    (let loop ()
      (define form (with-handlers ([exn:fail? (lambda (e) eof)]) (read port)))
      (cond
        [(eof-object? form) #f]
        [(match-define-syntax-parse-rule form macro-name)
         => values]
        [(match-define-syntax-rule form macro-name)
         => values]
        [else (loop)]))))

;; Strip #lang line and other reader directives that `read` can't handle
(define (strip-lang-lines text)
  (define lines (string-split text "\n"))
  (define filtered
    (for/list ([line lines])
      (if (or (string-prefix? line "#lang")
              (string-prefix? line "#reader"))
          ""
          line)))
  (string-join filtered "\n"))

;; Try to match a (define-syntax-parse-rule (name pattern ...) template ...) form
(define (match-define-syntax-parse-rule form macro-name)
  (match form
    [`(define-syntax-parse-rule (,(? symbol? name) . ,pattern-parts) . ,_)
     #:when (string=? (symbol->string name) macro-name)
     (define pattern-str (format "(~a ~a)"
                                 name
                                 (string-join (map ~a pattern-parts) " ")))
     (define vars (extract-variables pattern-parts))
     (hasheq 'pattern pattern-str
             'variables vars
             'source #f)]
    [_ #f]))

;; Try to match a (define-syntax-rule (name pattern ...) template ...) form
(define (match-define-syntax-rule form macro-name)
  (match form
    [`(define-syntax-rule (,(? symbol? name) . ,pattern-parts) . ,_)
     #:when (string=? (symbol->string name) macro-name)
     (define pattern-str (format "(~a ~a)"
                                 name
                                 (string-join (map ~a pattern-parts) " ")))
     (define vars (extract-variables pattern-parts))
     (hasheq 'pattern pattern-str
             'variables vars
             'source #f)]
    [_ #f]))

;; Extract variable names from pattern parts.
;; Handles: plain identifiers (x), annotated (x:expr), ellipsis patterns (x ...)
(define (extract-variables parts)
  (define colors '("#4CAF50" "#2196F3" "#FF9800" "#E91E63" "#9C27B0"
                   "#00BCD4" "#FF5722" "#795548"))
  (define var-list
    (let loop ([parts parts] [acc '()])
      (cond
        [(null? parts) (reverse acc)]
        [(symbol? (car parts))
         (define name-str (symbol->string (car parts)))
         (cond
           ;; Skip ellipsis and underscore
           [(member name-str '("..." "___" "_")) (loop (cdr parts) acc)]
           ;; Annotated: name:class
           [(string-contains? name-str ":")
            (define var-name (car (string-split name-str ":")))
            (loop (cdr parts) (cons var-name acc))]
           ;; Plain identifier
           [else (loop (cdr parts) (cons name-str acc))])]
        [(pair? (car parts))
         ;; Recurse into sub-patterns
         (define sub-vars (extract-variables (car parts)))
         (define sub-names (map (lambda (v) (hash-ref v 'name)) sub-vars))
         (loop (cdr parts) (append (reverse sub-names) acc))]
        [else (loop (cdr parts) acc)])))

  (for/list ([name (in-list var-list)]
             [i (in-naturals)])
    (hasheq 'name name
            'color (list-ref colors (modulo i (length colors))))))

;; Helper: convert any value to string
(define (~a v)
  (format "~a" v))
