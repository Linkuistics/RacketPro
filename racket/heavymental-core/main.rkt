#lang racket/base

(require racket/path
         "protocol.rkt"
         "cell.rkt"
         "editor.rkt"
         "repl.rkt"
         "lang-intel.rkt"
         "stepper.rkt"
         "macro-expander.rkt")

;; ── Cells ──────────────────────────────────────────────────
(define-cell current-file "")
(define-cell file-dirty #f)
(define-cell title "HeavyMental")
(define-cell status "Ready")
(define-cell language "")
(define-cell cursor-pos "")
(define-cell dirty-files (list))
(define-cell repl-running #f)
(define-cell project-root "")
(define-cell stepper-active #f)
(define-cell stepper-step 0)
(define-cell stepper-total -1)
(define-cell current-bottom-tab "terminal")
(define-cell macro-active #f)

;; Track which REPL generation was active when the last pty:create ran.
;; Used to ignore pty:exit events from stale (killed) REPL processes.
(define _last-repl-gen 0)

;; Track which language the current REPL is running.
;; Used to decide whether we need to restart the REPL when running a file.
(define _current-repl-lang "racket")

;; ── Layout ─────────────────────────────────────────────────
;; Zed-like layout:
;;   vbox (full height)
;;   ├── split (horizontal, 0.17)
;;   │   ├── filetree (root-path from cell)
;;   │   └── vbox (flex: 1)
;;   │       ├── tabs (open file tabs)
;;   │       ├── breadcrumb (file path + action buttons)
;;   │       └── split (vertical, 0.65)
;;   │           ├── editor
;;   │           └── terminal (REPL)
;;   └── statusbar (left: status | right: cursor pos, language)

(define initial-layout
  (hasheq 'type "vbox"
          'props (hasheq 'flex "1")
          'children
          (list
           ;; ── Main area: filetree | editor/terminal ──
           ;; Horizontal split: file tree on left, editor column on right
           (hasheq 'type "split"
                   'props (hasheq 'direction "horizontal"
                                  'ratio 0.17
                                  'min-size 120)
                   'children
                   (list
                    ;; File tree sidebar (left pane)
                    (hasheq 'type "filetree"
                            'props (hasheq 'root-path "cell:project-root")
                            'children (list))
                    ;; Editor + terminal column (right pane)
                    (hasheq 'type "vbox"
                            'props (hasheq 'flex "1")
                            'children
                            (list
                             ;; Tab bar
                             (hasheq 'type "tabs"
                                     'props (hasheq)
                                     'children (list))
                             ;; Breadcrumb: current file path + action buttons
                             (hasheq 'type "breadcrumb"
                                     'props (hasheq 'file "cell:current-file"
                                                    'root "cell:project-root")
                                     'children (list))
                             ;; Split: editor + REPL
                             (hasheq 'type "split"
                                     'props (hasheq 'direction "vertical"
                                                    'ratio 0.65)
                                     'children
                                     (list
                                      (hasheq 'type "editor"
                                              'props (hasheq 'file-path ""
                                                             'language "racket")
                                              'children (list))
                                      (hasheq 'type "vbox"
                                              'props (hasheq 'flex "1")
                                              'children
                                              (list
                                               ;; Bottom panel tab bar
                                               (hasheq 'type "bottom-tabs"
                                                       'props (hasheq 'tabs
                                                                      (list (hasheq 'id "terminal" 'label "Terminal")
                                                                            (hasheq 'id "problems" 'label "Problems")
                                                                            (hasheq 'id "stepper" 'label "Stepper")
                                                                            (hasheq 'id "macros" 'label "Macros")))
                                                       'children (list))
                                               ;; Tab content: only active tab's child is visible
                                               (hasheq 'type "tab-content"
                                                       'props (hasheq)
                                                       'children
                                                       (list
                                                        ;; TERMINAL tab
                                                        (hasheq 'type "terminal"
                                                                'props (hasheq 'pty-id "repl"
                                                                               'data-tab-id "terminal")
                                                                'children (list))
                                                        ;; PROBLEMS tab
                                                        (hasheq 'type "error-panel"
                                                                'props (hasheq 'data-tab-id "problems")
                                                                'children (list))
                                                        ;; STEPPER tab (vbox wrapping toolbar + bindings)
                                                        (hasheq 'type "vbox"
                                                                'props (hasheq 'data-tab-id "stepper"
                                                                               'flex "1")
                                                                'children
                                                                (list
                                                                 (hasheq 'type "stepper-toolbar"
                                                                         'props (hasheq)
                                                                         'children (list))
                                                                 (hasheq 'type "bindings-panel"
                                                                         'props (hasheq)
                                                                         'children (list))))
                                                        ;; MACROS tab (placeholder for now)
                                                        (hasheq 'type "macro-panel"
                                                                'props (hasheq 'data-tab-id "macros")
                                                                'children (list))))))))))))
           ;; ── Status bar ──
           (hasheq 'type "statusbar"
                   'props (hasheq 'content "cell:status"
                                  'language "cell:language"
                                  'position "cell:cursor-pos")
                   'children (list)))))

;; ── Menu ───────────────────────────────────────────────────
(define app-menu
  (list
   (hasheq 'label "File"
           'children
           (list
            (hasheq 'label "New" 'shortcut "Cmd+N" 'action "new-file")
            (hasheq 'label "Open..." 'shortcut "Cmd+O" 'action "open-file")
            (hasheq 'label "Save" 'shortcut "Cmd+S" 'action "save-file")))
   (hasheq 'label "Edit"
           'children
           (list
            (hasheq 'label "Undo" 'action "undo")
            (hasheq 'label "Redo" 'action "redo")
            (hasheq 'label "---")
            (hasheq 'label "Cut" 'action "cut")
            (hasheq 'label "Copy" 'action "copy")
            (hasheq 'label "Paste" 'action "paste")
            (hasheq 'label "---")
            (hasheq 'label "Select All" 'action "select-all")))
   (hasheq 'label "Racket"
           'children
           (list
            (hasheq 'label "Run" 'shortcut "Cmd+R" 'action "run")
            (hasheq 'label "---")
            (hasheq 'label "Step Through" 'shortcut "Cmd+Shift+R" 'action "step-through")
            (hasheq 'label "Stop Stepper" 'action "stop-stepper")
            (hasheq 'label "---")
            (hasheq 'label "Expand Macros" 'shortcut "Cmd+Shift+E" 'action "expand-macros")))))

;; ── Event handler ──────────────────────────────────────────
(define (handle-event msg)
  (define event-name (message-ref msg 'name ""))
  (cond
    [(string=? event-name "run")
     (handle-run)]
    [(or (string=? event-name "editor:dirty")
         (string=? event-name "editor:save-request"))
     (handle-editor-event msg)]
    ;; Toolbar button events (same actions as menu)
    [(string=? event-name "new-file") (new-file)]
    [(string=? event-name "open-file") (open-file)]
    [(string=? event-name "save-file")
     (send-message! (make-message "editor:request-save"))]
    ;; File tree: user clicked a file
    [(string=? event-name "file:tree-open")
     (define path (message-ref msg 'path ""))
     (when (not (string=? path ""))
       (send-message! (make-message "file:read" 'path path)))]
    ;; Tab bar: user requests to close a tab (may show dirty dialog)
    [(string=? event-name "tab:close-request")
     (define path (message-ref msg 'path ""))
     (when (not (string=? path ""))
       (handle-tab-close-request path))]
    ;; Tab bar: user clicked a tab
    [(string=? event-name "tab:select")
     (define path (message-ref msg 'path ""))
     (when (not (string=? path ""))
       (send-message! (make-message "file:read" 'path path)))]
    ;; Tab bar: all tabs closed — clear editor and cells
    [(string=? event-name "tab:close-all")
     (cell-set! 'current-file "")
     (cell-set! 'language "")
     (cell-set! 'cursor-pos "")
     (cell-set! 'status "")
     (cell-set! 'file-dirty #f)
     (send-message! (make-message "editor:set-content" 'content ""))]
    ;; Document sync for language intelligence
    [(string=? event-name "document:opened")
     (handle-document-opened msg)]
    [(string=? event-name "document:changed")
     (handle-document-changed msg)]
    [(string=? event-name "document:closed")
     (handle-document-closed msg)]
    ;; Editor navigation: jump to a specific position
    [(string=? event-name "editor:goto")
     (define line (message-ref msg 'line 1))
     (define col (message-ref msg 'col 0))
     (send-message! (make-message "editor:goto"
                                  'line line
                                  'col col))]
    ;; REPL error → jump to source file (uses pending-goto for proper sequencing)
    [(string=? event-name "editor:goto-file")
     (define path (message-ref msg 'path ""))
     (define line (message-ref msg 'line 1))
     (define col (message-ref msg 'col 0))
     (when (not (string=? path ""))
       (cond
         ;; If the file is already open, just goto
         [(string=? path (current-file-path))
          (send-message! (make-message "editor:goto" 'line line 'col col))]
         [else
          ;; Open the file first, then goto after it loads
          (set-pending-goto! path #:line line #:col col)
          (send-message! (make-message "file:read" 'path path))]))]
    ;; REPL restart
    [(string=? event-name "repl:restart")
     (cell-set! 'repl-running #f)
     (define path (current-file-path))
     (define lang (if (and path (not (string=? path "")))
                      (detect-language path)
                      "racket"))
     (define repl-lang (if (string=? lang "rhombus") "rhombus" "racket"))
     (set! _current-repl-lang repl-lang)
     (restart-repl #:language repl-lang)
     (set! _last-repl-gen (repl-generation))]
    ;; Completion request
    [(string=? event-name "intel:completion-request")
     (handle-completion-request msg)]
    ;; Stepper events
    [(string=? event-name "stepper:start")
     (define path (message-ref msg 'path (current-file-path)))
     (when (and path (not (string=? path "")) (not (string=? path "untitled.rkt")))
       (cond
         [(string=? (detect-language path) "rhombus")
          (send-message! (make-message "stepper:error"
                                       'error "The stepper is not yet supported for Rhombus files. It currently only works with #lang racket."))
          (cell-set! 'current-bottom-tab "stepper")]
         [else
          (start-stepper path)
          (cell-set! 'current-bottom-tab "stepper")]))]
    [(string=? event-name "stepper:stop")
     (stop-stepper)]
    [(string=? event-name "stepper:forward")
     (stepper-forward)]
    [(string=? event-name "stepper:back")
     (stepper-back)]
    [(string=? event-name "stepper:continue")
     (stepper-continue)]
    ;; Cross-file go-to-definition (from lang-intel.js definition provider)
    [(string=? event-name "editor:goto-definition")
     (define path (message-ref msg 'path ""))
     (define name (message-ref msg 'name ""))
     (when (and (not (string=? path ""))
                (not (string=? name "")))
       (cond
         ;; If the file is already open, analyze and jump
         [(string=? path (current-file-path))
          ;; Already open — run check-syntax to find definition
          (void)] ;; Same-file definitions are handled by arrows, not jump targets
         [else
          ;; Open file, then find definition after it loads
          (set-pending-goto! path #:name name)
          (send-message! (make-message "file:read" 'path path))]))]
    ;; Macro expander events
    [(string=? event-name "macro:expand")
     (define path (message-ref msg 'path (current-file-path)))
     (when (and path (not (string=? path "")) (not (string=? path "untitled.rkt")))
       (start-macro-expander path))]
    [(string=? event-name "macro:stop")
     (stop-macro-expander)]
    ;; Bottom panel tab selection
    [(string=? event-name "bottom-tab:select")
     (define tab (message-ref msg 'tab "terminal"))
     (cell-set! 'current-bottom-tab tab)]
    [else
     (eprintf "Unknown event: ~a\n" event-name)]))

;; ── Menu action handler ───────────────────────────────────
(define (handle-menu-action msg)
  (define action (message-ref msg 'action ""))
  (cond
    [(string=? action "quit") (exit 0)]
    [(string=? action "new-file") (new-file)]
    [(string=? action "open-file") (open-file)]
    [(string=? action "save-file")
     ;; Ask frontend to trigger a save (Monaco owns the buffer content)
     (send-message! (make-message "editor:request-save"))]
    [(string=? action "run") (handle-run)]
    [(string=? action "step-through")
     (define path (current-file-path))
     (when (and path (not (string=? path "")) (not (string=? path "untitled.rkt")))
       (cond
         [(string=? (detect-language path) "rhombus")
          (send-message! (make-message "stepper:error"
                                       'error "The stepper is not yet supported for Rhombus files. It currently only works with #lang racket."))
          (cell-set! 'current-bottom-tab "stepper")]
         [else
          (start-stepper path)
          (cell-set! 'current-bottom-tab "stepper")]))]
    [(string=? action "stop-stepper")
     (stop-stepper)]
    [(string=? action "expand-macros")
     (define path (current-file-path))
     (when (and path (not (string=? path "")) (not (string=? path "untitled.rkt")))
       (start-macro-expander path))]
    [else
     (eprintf "Unhandled menu action: ~a\n" action)]))

;; ── Run handler ────────────────────────────────────────────
(define (handle-run)
  (define path (current-file-path))
  (cond
    [(or (not path) (string=? path "") (string=? path "untitled.rkt")) (void)]
    [(file-dirty? path)
     (set-pending-run!)
     (send-message! (make-message "editor:request-save"))]
    [else
     (define lang (detect-language path))
     (define repl-lang (if (string=? lang "rhombus") "rhombus" "racket"))
     ;; If the REPL language doesn't match, restart with the right one
     (when (not (string=? repl-lang _current-repl-lang))
       (set! _current-repl-lang repl-lang)
       (restart-repl #:language repl-lang)
       (set! _last-repl-gen (repl-generation)))
     (cell-set! 'repl-running #t)
     (clear-repl)
     (run-file path)]))

;; ── Message dispatcher ─────────────────────────────────────
(define (dispatch msg)
  (define typ (message-type msg))
  (cond
    [(string=? typ "event") (handle-event msg)]
    [(string=? typ "menu:action") (handle-menu-action msg)]
    ;; File operation results from Rust
    [(or (string=? typ "file:read:result")
         (string=? typ "file:write:result")
         (string=? typ "file:read:error")
         (string=? typ "file:write:error")
         (string=? typ "file:open-dialog:cancelled")
         (string=? typ "file:save-dialog:cancelled"))
     (handle-file-result msg)
     ;; After a successful write, check for deferred actions
     (when (string=? typ "file:write:result")
       (define path (message-ref msg 'path ""))
       (when (pending-run?)
         (clear-pending-run!)
         (cell-set! 'repl-running #t)
         (clear-repl)
         (run-file path))
       (when (pending-close? path)
         (clear-pending-close! path)
         (send-message! (make-message "tab:close" 'path path)))
       (when (pending-quit?)
         (clear-pending-quit!)
         (send-message! (make-message "lifecycle:quit"))))]
    ;; Lifecycle: window close request — check for unsaved changes
    [(string=? typ "lifecycle:close-request")
     (handle-close-request)]
    ;; Dialog results (e.g., save-before-close confirmation)
    [(string=? typ "dialog:confirm:result")
     (handle-dialog-result msg)]
    ;; PTY events — only clear repl-running if the REPL hasn't been
    ;; restarted since this PTY was created. Each start-repl increments
    ;; the generation; if it's higher than what we recorded at the last
    ;; pty:create, this exit is from a stale (killed) REPL.
    [(string=? typ "pty:exit")
     (when (= _last-repl-gen (repl-generation))
       (cell-set! 'repl-running #f))
     (handle-repl-event msg)]
    [(string=? typ "ping")
     (send-message! (make-message "pong"))]
    [else
     (eprintf "Unknown message type: ~a\n" typ)]))

;; ── Startup sequence ───────────────────────────────────────

;; Derive project root from the script's location (up 2 levels from main.rkt)
(let ()
  (define run-path (find-system-path 'run-file))
  (define dir (simplify-path (build-path run-path 'up 'up 'up)))
  (define dir-str (path->string dir))
  (cell-set! 'project-root dir-str)
  (eprintf "Project root: ~a\n" dir-str))

(register-all-cells!)
(send-message! (make-message "menu:set" 'menu app-menu))
(send-message! (make-message "layout:set" 'layout initial-layout))

;; Start REPL PTY
(start-repl)
(set! _last-repl-gen (repl-generation))

(send-message! (make-message "lifecycle:ready"))
(start-message-loop dispatch)
