#lang racket/base

(require racket/path
         "protocol.rkt"
         "cell.rkt"
         "editor.rkt"
         "repl.rkt"
         "lang-intel.rkt")

;; ── Cells ──────────────────────────────────────────────────
(define-cell current-file "")
(define-cell file-dirty #f)
(define-cell title "HeavyMental")
(define-cell status "Ready")
(define-cell language "")
(define-cell cursor-pos "")
(define-cell dirty-files (list))
(define-cell project-root "")

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
                                               (hasheq 'type "panel-header"
                                                       'props (hasheq 'label "TERMINAL")
                                                       'children (list))
                                               (hasheq 'type "terminal"
                                                       'props (hasheq 'pty-id "repl")
                                                       'children (list))
                                               (hasheq 'type "panel-header"
                                                       'props (hasheq 'label "PROBLEMS")
                                                       'children (list))
                                               (hasheq 'type "error-panel"
                                                       'props (hasheq)
                                                       'children (list))))))))))
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
            (hasheq 'label "Run" 'shortcut "Cmd+R" 'action "run")))))

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
    ;; REPL error → jump to source file
    [(string=? event-name "editor:goto-file")
     (define path (message-ref msg 'path ""))
     (define line (message-ref msg 'line 1))
     (define col (message-ref msg 'col 0))
     (when (not (string=? path ""))
       ;; Open the file in the editor, then jump to position
       (send-message! (make-message "file:read" 'path path))
       ;; Queue a goto after the file is opened
       ;; TODO: proper sequencing — file:read:result triggers editor:set-content,
       ;; and the goto should happen after that completes.
       (send-message! (make-message "editor:goto"
                                    'line line
                                    'col col)))]
    ;; Completion request
    [(string=? event-name "intel:completion-request")
     (handle-completion-request msg)]
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
    [else
     (eprintf "Unhandled menu action: ~a\n" action)]))

;; ── Run handler ────────────────────────────────────────────
(define (handle-run)
  (define path (current-file-path))
  (when (and path (not (string=? path "untitled.rkt")))
    (run-file path)))

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
     (handle-file-result msg)]
    ;; Dialog results (e.g., save-before-close confirmation)
    [(string=? typ "dialog:confirm:result")
     (handle-dialog-result msg)]
    ;; PTY events
    [(string=? typ "pty:exit")
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

(send-message! (make-message "lifecycle:ready"))
(start-message-loop dispatch)
