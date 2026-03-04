#lang racket/base

(require racket/class
         racket/list
         racket/string
         syntax/modread
         drracket/check-syntax
         "protocol.rkt")

(provide analyze-source
         push-intel-to-frontend!
         offset->position
         handle-document-opened
         handle-document-changed
         handle-document-closed
         handle-completion-request)

;; ── Trace collector ────────────────────────────────────────

;; Collects check-syntax annotations into lists for JSON serialization.
(define build-trace%
  (class (annotations-mixin object%)
    (init-field src)

    (define arrows '())
    (define hovers '())
    (define colors '())
    (define definitions '())
    (define jump-targets '())
    (define diagnostics '())

    (define/public (get-arrows) (reverse arrows))
    (define/public (get-hovers) (reverse hovers))
    (define/public (get-colors) (reverse colors))
    (define/public (get-definitions) (reverse definitions))
    (define/public (get-jump-targets) (reverse jump-targets))
    (define/public (get-diagnostics) (reverse diagnostics))

    ;; Only process annotations for our source file
    (define/override (syncheck:find-source-object stx)
      (and (equal? src (syntax-source stx)) src))

    ;; Binding arrows
    ;; require-arrow? is #f for normal bindings, or a string (e.g. "module-lang")
    ;; for require-related arrows.
    (define/override (syncheck:add-arrow/name-dup/pxpy
                      start-src start-left start-right start-px start-py
                      end-src end-left end-right end-px end-py
                      actual? phase require-arrow? name-dup?)
      (set! arrows
            (cons (hasheq 'from start-left
                          'fromEnd start-right
                          'to end-left
                          'toEnd end-right
                          'kind (cond [(and require-arrow? (not (eq? require-arrow? #f)))
                                       "require"]
                                      [actual? "binding"]
                                      [else "tail"]))
                  arrows)))

    ;; Tail arrows
    (define/override (syncheck:add-tail-arrow from-src from-pos to-src to-pos)
      (set! arrows
            (cons (hasheq 'from from-pos
                          'fromEnd (add1 from-pos)
                          'to to-pos
                          'toEnd (add1 to-pos)
                          'kind "tail")
                  arrows)))

    ;; Hover text
    (define/override (syncheck:add-mouse-over-status _src left right text)
      (set! hovers
            (cons (hasheq 'from left 'to right 'text text)
                  hovers)))

    ;; Semantic coloring
    (define/override (syncheck:color-range _src start end style-name)
      (define style
        (cond
          [(string-contains? style-name "lexically-bound") "lexically-bound"]
          [(string-contains? style-name "imported") "imported"]
          [(string-contains? style-name "set!d") "set!d"]
          [(string-contains? style-name "free-variable") "free-variable"]
          [(string-contains? style-name "unused-require") "unused-require"]
          [else style-name]))
      (set! colors
            (cons (hasheq 'from start 'to end 'style style)
                  colors)))

    ;; Definition targets
    (define/override (syncheck:add-definition-target/phase-level+space
                      _src left right id _mods _phase+space)
      (set! definitions
            (cons (hasheq 'from left 'to right
                          'name (symbol->string id))
                  definitions)))

    ;; Jump to definition (cross-file)
    (define/override (syncheck:add-jump-to-definition/phase-level+space
                      _src left right id path _mods _phase+space)
      (set! jump-targets
            (cons (hasheq 'from left 'to right
                          'name (symbol->string id)
                          'path (if (string? path) path
                                    (if (path? path) (path->string path) "")))
                  jump-targets)))

    ;; Unused requires
    (define/override (syncheck:add-unused-require _src left right)
      (set! diagnostics
            (cons (hasheq 'from left 'to right
                          'severity "warning"
                          'message "Unused require"
                          'source "check-syntax")
                  diagnostics)))

    (super-new)))

;; ── Analysis ───────────────────────────────────────────────

;; Analyze source code using check-syntax.
;; Returns a hasheq with keys: arrows, hovers, colors, definitions,
;; jump-targets, diagnostics.
(define (analyze-source uri text)
  (define trace (new build-trace% [src uri]))
  (define error-diagnostics '())

  (with-handlers
    ([exn:fail?
      (lambda (e)
        (set! error-diagnostics
              (list (hasheq 'from 0 'to (min 1 (string-length text))
                            'severity "error"
                            'message (exn-message e)
                            'source "check-syntax"))))])

    (define port (open-input-string text))
    (port-count-lines! port)

    (define-values (expanded-expression expansion-completed)
      (make-traversal (make-base-namespace) uri))

    (parameterize ([current-annotations trace]
                   [current-namespace (make-base-namespace)])
      (expanded-expression
       (expand
        (with-module-reading-parameterization
          (lambda () (read-syntax uri port)))))
      (expansion-completed)))

  (hasheq 'arrows (send trace get-arrows)
          'hovers (send trace get-hovers)
          'colors (send trace get-colors)
          'definitions (send trace get-definitions)
          'jump-targets (send trace get-jump-targets)
          'diagnostics (append (send trace get-diagnostics)
                               error-diagnostics)))

;; ── Offset → Line/Col conversion ──────────────────────────

;; Convert a character offset to {line, col} (1-based lines, 0-based cols)
;; matching Monaco's convention.
(define (offset->position text offset)
  (define safe-offset (min offset (string-length text)))
  (define prefix (substring text 0 safe-offset))
  (define lines (string-split prefix "\n" #:trim? #f))
  (define line-count (max 1 (length lines)))
  (define last-line (if (null? lines) "" (last lines)))
  (hasheq 'line line-count
          'col (string-length last-line)))

;; Convert a from/to offset pair to a Monaco range
(define (offsets->range text from to)
  (define start (offset->position text from))
  (define end-pos (offset->position text to))
  (hasheq 'startLine (hash-ref start 'line)
          'startCol (hash-ref start 'col)
          'endLine (hash-ref end-pos 'line)
          'endCol (hash-ref end-pos 'col)))

;; ── Intel cache ────────────────────────────────────────────

;; Cache of analysis results per URI
(define intel-cache (make-hash))

;; Cache entry stores the text (for offset conversion) and the trace results
(struct intel-entry (text result) #:transparent)

;; ── Push results to frontend ───────────────────────────────

(define (push-intel-to-frontend! uri text result)
  ;; Store in cache for later lookups (hover, definition, completion requests)
  (hash-set! intel-cache uri (intel-entry text result))

  ;; Diagnostics
  (define diags
    (for/list ([d (in-list (hash-ref result 'diagnostics))])
      (define range (offsets->range text
                                    (hash-ref d 'from)
                                    (hash-ref d 'to)))
      (hasheq 'range range
              'severity (hash-ref d 'severity)
              'message (hash-ref d 'message)
              'source (hash-ref d 'source "check-syntax"))))
  (send-message! (make-message "intel:diagnostics"
                               'uri uri
                               'items diags))

  ;; Arrows
  (define arrow-data
    (for/list ([a (in-list (hash-ref result 'arrows))])
      (define from-range (offsets->range text
                                         (hash-ref a 'from)
                                         (hash-ref a 'fromEnd)))
      (define to-range (offsets->range text
                                       (hash-ref a 'to)
                                       (hash-ref a 'toEnd)))
      (hasheq 'from from-range
              'to to-range
              'kind (hash-ref a 'kind))))
  (send-message! (make-message "intel:arrows"
                               'uri uri
                               'arrows arrow-data))

  ;; Hovers
  (define hover-data
    (for/list ([h (in-list (hash-ref result 'hovers))])
      (define range (offsets->range text
                                    (hash-ref h 'from)
                                    (hash-ref h 'to)))
      (hasheq 'range range
              'contents (hash-ref h 'text))))
  (send-message! (make-message "intel:hovers"
                               'uri uri
                               'hovers hover-data))

  ;; Colors
  (define color-data
    (for/list ([c (in-list (hash-ref result 'colors))])
      (define range (offsets->range text
                                    (hash-ref c 'from)
                                    (hash-ref c 'to)))
      (hasheq 'range range
              'style (hash-ref c 'style))))
  (send-message! (make-message "intel:colors"
                               'uri uri
                               'colors color-data))

  ;; Definitions (for go-to-definition within file)
  (define def-data
    (for/list ([d (in-list (hash-ref result 'definitions))])
      (define range (offsets->range text
                                    (hash-ref d 'from)
                                    (hash-ref d 'to)))
      (hasheq 'range range
              'name (hash-ref d 'name))))
  ;; Jump targets (for go-to-definition cross-file)
  (define jump-data
    (for/list ([j (in-list (hash-ref result 'jump-targets))])
      (define range (offsets->range text
                                    (hash-ref j 'from)
                                    (hash-ref j 'to)))
      (hasheq 'range range
              'name (hash-ref j 'name)
              'targetUri (hash-ref j 'path))))
  (send-message! (make-message "intel:definitions"
                               'uri uri
                               'defs def-data
                               'jumps jump-data)))

;; ── Event handlers (called from main.rkt dispatch) ────────

(define (handle-document-opened msg)
  (define uri (message-ref msg 'uri ""))
  (define text (message-ref msg 'text ""))
  (when (and (not (string=? uri ""))
             (not (string=? text "")))
    (eprintf "[lang-intel] Analyzing ~a (~a chars)...\n"
             uri (string-length text))
    (define result (analyze-source uri text))
    (push-intel-to-frontend! uri text result)
    (eprintf "[lang-intel] Analysis complete: ~a diagnostics, ~a arrows\n"
             (length (hash-ref result 'diagnostics))
             (length (hash-ref result 'arrows)))))

(define (handle-document-changed msg)
  (define uri (message-ref msg 'uri ""))
  (define text (message-ref msg 'text ""))
  (when (and (not (string=? uri ""))
             (not (string=? text "")))
    ;; Re-analyze (debouncing is done on the frontend side)
    (eprintf "[lang-intel] Re-analyzing ~a...\n" uri)
    (define result (analyze-source uri text))
    (push-intel-to-frontend! uri text result)))

(define (handle-document-closed msg)
  (define uri (message-ref msg 'uri ""))
  (hash-remove! intel-cache uri)
  (send-message! (make-message "intel:clear" 'uri uri)))

(define (handle-completion-request msg)
  (define uri (message-ref msg 'uri ""))
  (define id (message-ref msg 'id 0))
  (define prefix (message-ref msg 'prefix ""))
  (define entry (hash-ref intel-cache uri #f))
  (define items
    (if entry
        (let* ([result (intel-entry-result entry)]
               [defs (hash-ref result 'definitions)]
               [names (map (lambda (d) (hash-ref d 'name)) defs)]
               [filtered (if (string=? prefix "")
                             names
                             (filter (lambda (n)
                                       (string-prefix? n prefix))
                                     names))])
          (for/list ([name (in-list filtered)])
            (hasheq 'label name
                    'kind "variable")))
        '()))
  (send-message! (make-message "intel:completion-response"
                               'id id
                               'items items)))
