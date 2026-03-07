#lang racket/base

(require racket/list
         racket/string
         racket/hash
         "protocol.rkt"
         "cell.rkt")

(provide define-extension
         extension-descriptor
         extension-descriptor?
         extension-descriptor-id
         extension-descriptor-name
         extension-descriptor-cells
         extension-descriptor-panels
         extension-descriptor-events
         extension-descriptor-menus
         extension-descriptor-on-activate
         extension-descriptor-on-deactivate
         load-extension!
         load-extension-descriptor!
         unload-extension!
         reload-extension!
         list-extensions
         get-extension-handler
         get-extension-layout-contributions
         assign-layout-ids
         watch-directory!
         unwatch-all!
         handle-fs-change)

;; ── Descriptor struct ────────────────────────────────────────────────────────

(struct extension-descriptor
  (id name cells panels events menus on-activate on-deactivate)
  #:transparent)

;; ── define-extension macro ───────────────────────────────────────────────────
;;
;; Usage:
;;   (define-extension ext-id
;;     #:name "Human Name"
;;     #:cells ([cell-name initial-value] ...)
;;     #:panels ([#:id "id" #:label "Label" #:tab 'bottom #:layout expr] ...)
;;     #:events ([#:name "name" #:handler proc] ...)
;;     #:menus ([#:menu "Menu" #:label "Label" #:shortcut "Cmd+X" #:action "act"] ...)
;;     #:on-activate thunk
;;     #:on-deactivate thunk)
;;
;; All clauses except #:name are optional.
;; Clauses can appear in any order after #:name.

(define-syntax define-extension
  (syntax-rules ()
    [(_ ext-id #:name name-val rest ...)
     (define ext-id
       (build-extension-descriptor/accum
        ext-id name-val
        (list) (list) (list) (list) #f #f
        rest ...))]))

;; Accumulator macro that processes remaining keyword arguments.
;;
;; Pattern variables use _ext- prefix to avoid shadowing template symbols.
;; In syntax-rules, (quote x) in the template quotes the binding of
;; pattern variable x, NOT the literal symbol x. So accumulator variable
;; names must not collide with hash key names used in templates.
(define-syntax build-extension-descriptor/accum
  (syntax-rules ()
    ;; Done -- no more clauses, build the struct
    [(_ _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
        _ext-activate _ext-deactivate)
     (extension-descriptor '_ext-id _ext-name
                           _ext-cells _ext-panels _ext-events _ext-menus
                           _ext-activate _ext-deactivate)]

    ;; #:cells ([name val] ...)
    [(_ _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
        _ext-activate _ext-deactivate
        #:cells ([cell-name cell-val] ...) rest ...)
     (build-extension-descriptor/accum
      _ext-id _ext-name
      (list (cons 'cell-name cell-val) ...)
      _ext-panels _ext-events _ext-menus _ext-activate _ext-deactivate
      rest ...)]

    ;; #:panels ([#:id pid #:label plabel #:tab ptab #:layout playout] ...)
    [(_ _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
        _ext-activate _ext-deactivate
        #:panels ([#:id pid #:label plabel #:tab ptab #:layout playout] ...) rest ...)
     (build-extension-descriptor/accum
      _ext-id _ext-name _ext-cells
      (list (hasheq 'id pid 'label plabel 'tab ptab 'layout playout) ...)
      _ext-events _ext-menus _ext-activate _ext-deactivate
      rest ...)]

    ;; #:events ([#:name ename #:handler ehandler] ...)
    [(_ _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
        _ext-activate _ext-deactivate
        #:events ([#:name ename #:handler ehandler] ...) rest ...)
     (build-extension-descriptor/accum
      _ext-id _ext-name _ext-cells _ext-panels
      (list (hasheq 'name ename 'handler ehandler) ...)
      _ext-menus _ext-activate _ext-deactivate
      rest ...)]

    ;; #:menus ([#:menu mmenu #:label mlabel #:shortcut mshortcut #:action maction] ...)
    [(_ _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
        _ext-activate _ext-deactivate
        #:menus ([#:menu mmenu #:label mlabel #:shortcut mshortcut #:action maction] ...) rest ...)
     (build-extension-descriptor/accum
      _ext-id _ext-name _ext-cells _ext-panels _ext-events
      (list (hasheq 'menu mmenu 'label mlabel 'shortcut mshortcut 'action maction) ...)
      _ext-activate _ext-deactivate
      rest ...)]

    ;; #:on-activate thunk
    [(_ _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
        _ext-activate _ext-deactivate
        #:on-activate new-activate rest ...)
     (build-extension-descriptor/accum
      _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
      new-activate _ext-deactivate
      rest ...)]

    ;; #:on-deactivate thunk
    [(_ _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
        _ext-activate _ext-deactivate
        #:on-deactivate new-deactivate rest ...)
     (build-extension-descriptor/accum
      _ext-id _ext-name _ext-cells _ext-panels _ext-events _ext-menus
      _ext-activate new-deactivate
      rest ...)]))

;; ── Extension registry ───────────────────────────────────────────────────────

;; Loaded extensions: symbol id → extension-descriptor
(define loaded-extensions (make-hasheq))

;; Extension event dispatch table: string "ext-id:event-name" → handler proc
(define extension-handlers (make-hash))

;; ── Namespacing helpers ──────────────────────────────────────────────────────

;; Prefix a cell name symbol: 'counter → 'my-ext:counter
(define (prefix-cell-name ext-id cell-name)
  (string->symbol (format "~a:~a" ext-id cell-name)))

;; Prefix an event name string: "click" → "my-ext:click"
(define (prefix-event-name ext-id event-name)
  (format "~a:~a" ext-id event-name))

;; Rewrite cell references in a layout tree:
;; "cell:counter" → "cell:my-ext:counter"
(define (rewrite-cell-refs ext-id layout)
  (cond
    [(hash? layout)
     (define new-props
       (if (hash-has-key? layout 'props)
           (for/hasheq ([(k v) (in-hash (hash-ref layout 'props (hasheq)))])
             (values k (rewrite-cell-ref-value ext-id v)))
           (hasheq)))
     (define new-children
       (if (hash-has-key? layout 'children)
           (for/list ([child (in-list (hash-ref layout 'children '()))])
             (rewrite-cell-refs ext-id child))
           '()))
     (hash-set* layout
                'props new-props
                'children new-children)]
    [else layout]))

(define (rewrite-cell-ref-value ext-id value)
  (cond
    [(and (string? value) (string-prefix? value "cell:"))
     (define cell-name (substring value 5))
     ;; Don't rewrite if already namespaced
     (if (string-contains? cell-name ":")
         value
         (format "cell:~a:~a" ext-id cell-name))]
    [else value]))

;; Rewrite on-click event references: "increment" → "my-ext:increment"
(define (rewrite-event-refs ext-id layout)
  (cond
    [(hash? layout)
     (define props (hash-ref layout 'props (hasheq)))
     (define new-props
       (for/hasheq ([(k v) (in-hash props)])
         (values k
                 (if (and (eq? k 'on-click) (string? v)
                          (not (string-contains? v ":")))
                     (prefix-event-name ext-id v)
                     v))))
     (define new-children
       (for/list ([child (in-list (hash-ref layout 'children '()))])
         (rewrite-event-refs ext-id child)))
     (hash-set* layout
                'props new-props
                'children new-children)]
    [else layout]))

;; ── Loading ──────────────────────────────────────────────────────────────────

;; Load from a descriptor object (used in tests and internally)
(define (load-extension-descriptor! desc)
  (define id (extension-descriptor-id desc))
  (define id-str (symbol->string id))

  ;; Register namespaced cells
  (for ([cell-spec (in-list (extension-descriptor-cells desc))])
    (define prefixed (prefix-cell-name id (car cell-spec)))
    (make-cell prefixed (cdr cell-spec))
    (send-message! (make-message "cell:register"
                                 'name (symbol->string prefixed)
                                 'value (cdr cell-spec))))

  ;; Register namespaced event handlers
  (for ([event-spec (in-list (extension-descriptor-events desc))])
    (define prefixed (prefix-event-name id-str (hash-ref event-spec 'name)))
    (hash-set! extension-handlers prefixed (hash-ref event-spec 'handler)))

  ;; Store in registry
  (hash-set! loaded-extensions id desc)

  ;; Call on-activate
  (define activate (extension-descriptor-on-activate desc))
  (when (and activate (procedure? activate))
    (activate)))

;; Load from a file path (dynamic-require)
(define (load-extension! path)
  (define mod-path (if (path? path) path (string->path path)))
  (define desc (dynamic-require mod-path 'extension #:fail-thunk
                                (lambda ()
                                  (error 'load-extension!
                                         "module at ~a does not provide 'extension"
                                         path))))
  (unless (extension-descriptor? desc)
    (error 'load-extension!
           "module at ~a: 'extension is not an extension-descriptor" path))
  (load-extension-descriptor! desc))

;; ── Unloading ────────────────────────────────────────────────────────────────

(define (unload-extension! ext-id)
  (define desc (hash-ref loaded-extensions ext-id #f))
  (unless desc
    (error 'unload-extension! "extension not loaded: ~a" ext-id))

  (define id-str (symbol->string ext-id))

  ;; Call on-deactivate
  (define deactivate (extension-descriptor-on-deactivate desc))
  (when (and deactivate (procedure? deactivate))
    (deactivate))

  ;; Unregister event handlers
  (for ([event-spec (in-list (extension-descriptor-events desc))])
    (define prefixed (prefix-event-name id-str (hash-ref event-spec 'name)))
    (hash-remove! extension-handlers prefixed))

  ;; Unregister cells
  (for ([cell-spec (in-list (extension-descriptor-cells desc))])
    (define prefixed (prefix-cell-name ext-id (car cell-spec)))
    (cell-unregister! prefixed))

  ;; Remove from registry
  (hash-remove! loaded-extensions ext-id))

;; ── Reload ───────────────────────────────────────────────────────────────────

(define (reload-extension! path)
  (load-extension! path))

;; ── Queries ──────────────────────────────────────────────────────────────────

(define (list-extensions)
  (hash-values loaded-extensions))

(define (get-extension-handler event-name)
  (hash-ref extension-handlers event-name #f))

;; Collect all panel layout contributions from loaded extensions
(define (get-extension-layout-contributions)
  (apply append
         (for/list ([(id desc) (in-hash loaded-extensions)])
           (define id-str (symbol->string id))
           (for/list ([panel (in-list (extension-descriptor-panels desc))])
             (define layout (hash-ref panel 'layout (hasheq)))
             (define rewritten
               (rewrite-event-refs id-str
                 (rewrite-cell-refs id-str layout)))
             (define panel-id (format "~a:~a" id-str (hash-ref panel 'id "")))
             (hasheq 'id panel-id
                     'label (hash-ref panel 'label "Extension")
                     'tab (hash-ref panel 'tab 'bottom)
                     'layout (hash-set* rewritten
                                        'props (hash-set (hash-ref rewritten 'props (hasheq))
                                                         'data-tab-id panel-id)))))))

;; ── Layout ID assignment ─────────────────────────────────────────────────────

;; Walk a layout tree and assign 'id to any node missing one.
;; IDs are generated from parent-id + type + sibling index: "vbox/editor-0", etc.
;; Nodes that already have an 'id in their props are left unchanged.
;; `parent-id` is the resolved ID of the parent node (empty string for the root).
(define (assign-layout-ids tree [parent-id ""])
  (cond
    [(hash? tree)
     (define node-type (hash-ref tree 'type "node"))
     (define props (hash-ref tree 'props (hasheq)))
     (define existing-id (hash-ref props 'id #f))
     ;; Root nodes (no parent) get their type as ID; children get parent-id as
     ;; their pre-computed ID (parent already formatted "parent/type-idx").
     (define node-id (or existing-id
                         (if (string=? parent-id "")
                             node-type
                             parent-id)))
     ;; Assign ID if missing
     (define new-props
       (if existing-id props (hash-set props 'id node-id)))
     ;; Recurse into children, using sibling index to disambiguate
     (define children (hash-ref tree 'children '()))
     (define type-counts (make-hash))  ;; track sibling indices by type
     (define new-children
       (for/list ([child (in-list children)])
         (define child-type (if (hash? child) (hash-ref child 'type "node") "node"))
         (define idx (hash-ref type-counts child-type 0))
         (hash-set! type-counts child-type (add1 idx))
         (define child-id (format "~a/~a-~a" node-id child-type idx))
         (assign-layout-ids child child-id)))
     (hash-set* tree
                'props new-props
                'children new-children)]
    [else tree]))

;; ── Filesystem watcher API ───────────────────────────────────────────────────

;; Active watcher callbacks: watch-id → callback
(define fs-watch-callbacks (make-hash))
(define _next-watch-id 0)

;; Start watching a directory. Callback receives (event-type path-string).
;; Returns a watch-id string.
(define (watch-directory! path callback)
  (set! _next-watch-id (add1 _next-watch-id))
  (define watch-id (format "watch-~a" _next-watch-id))
  (hash-set! fs-watch-callbacks watch-id callback)
  (send-message! (make-message "fs:watch"
                               'id watch-id
                               'path path))
  watch-id)

;; Stop all filesystem watchers
(define (unwatch-all!)
  (send-message! (make-message "fs:unwatch-all"))
  (hash-clear! fs-watch-callbacks))

;; Handle fs:change events from Rust (called by dispatch in main.rkt)
(define (handle-fs-change msg)
  (define watch-id (message-ref msg 'watch-id ""))
  (define event-type (message-ref msg 'event ""))
  (define path (message-ref msg 'path ""))
  (define callback (hash-ref fs-watch-callbacks watch-id #f))
  (when callback
    (callback event-type path)))
