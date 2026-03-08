#lang racket/base

(require racket/path
         racket/list
         "protocol.rkt"
         "cell.rkt"
         "editor.rkt"
         "repl.rkt"
         "lang-intel.rkt"
         "stepper.rkt"
         "macro-expander.rkt"
         "extension.rkt"
         "handler-registry.rkt"
         "settings.rkt"
         "theme.rkt"
         "project.rkt"
         "keybindings.rkt")

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
(define-cell _reload-status "")
(define-cell _extensions-list '())
(define-cell _current-theme "Light")
(define-cell _project-name "")

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
                                                                            (hasheq 'id "macros" 'label "Macros")
                                                                            (hasheq 'id "extensions" 'label "Extensions")
                                                                            (hasheq 'id "search" 'label "Search")))
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
                                                                'children (list))
                                                        ;; EXTENSIONS tab
                                                        (hasheq 'type "extension-manager"
                                                                'props (hasheq 'data-tab-id "extensions")
                                                                'children (list))
                                                        ;; SEARCH tab
                                                        (hasheq 'type "search-panel"
                                                                'props (hasheq 'data-tab-id "search")
                                                                'children (list))))))))))))
           ;; ── Status bar ──
           (hasheq 'type "statusbar"
                   'props (hasheq 'content "cell:status"
                                  'language "cell:language"
                                  'position "cell:cursor-pos")
                   'children (list)))))

;; ── Layout rebuild with extension panels ─────────────────────────
;; Rebuild and re-send the layout, merging extension panel contributions
;; into the bottom tabs area.
(define previous-layout #f)  ;; track the last sent layout for handler cleanup

(define (rebuild-layout!)
  (define ext-panels (get-extension-layout-contributions))
  (define new-layout (assign-layout-ids (merge-extension-panels initial-layout ext-panels)))

  ;; Cleanup orphaned handlers: remove _h: handlers that were in the old
  ;; layout but are not in the new one
  (when previous-layout
    (define old-ids (collect-handler-ids previous-layout))
    (define new-ids (collect-handler-ids new-layout))
    (define orphaned (remove* new-ids old-ids equal?))
    (when (not (null? orphaned))
      (remove-handlers! orphaned)))
  (set! previous-layout new-layout)

  (send-message! (make-message "layout:set" 'layout new-layout))
  (rebuild-menu!))

;; Merge extension panels into the layout tree.
;; Extension panels with 'tab = 'bottom are added as children of the
;; bottom-tabs tab-content, and their tab definitions are added to the
;; bottom-tabs component.
(define (merge-extension-panels layout ext-panels)
  (define bottom-panels (filter (lambda (p) (eq? (hash-ref p 'tab 'bottom) 'bottom))
                                ext-panels))
  (if (null? bottom-panels)
      layout
      (add-bottom-tab-panels layout bottom-panels)))

;; Walk the layout tree and inject extension panels into bottom-tabs
(define (add-bottom-tab-panels node ext-panels)
  (define node-type (hash-ref node 'type ""))
  (cond
    ;; Found the bottom-tabs: add extension tab definitions
    [(string=? node-type "bottom-tabs")
     (define existing-tabs (hash-ref (hash-ref node 'props (hasheq)) 'tabs '()))
     (define new-tabs
       (append existing-tabs
               (for/list ([p (in-list ext-panels)])
                 (hasheq 'id (hash-ref p 'id "")
                         'label (hash-ref p 'label "Extension")))))
     (hash-set node 'props
               (hash-set (hash-ref node 'props (hasheq)) 'tabs new-tabs))]
    ;; Found the tab-content: add extension panel layouts as children
    [(string=? node-type "tab-content")
     (define existing-children (hash-ref node 'children '()))
     (define new-children
       (append existing-children
               (for/list ([p (in-list ext-panels)])
                 (hash-ref p 'layout (hasheq)))))
     (hash-set node 'children new-children)]
    ;; Otherwise: recurse into children
    [else
     (define children (hash-ref node 'children '()))
     (if (null? children)
         node
         (hash-set node 'children
                   (for/list ([child (in-list children)])
                     (add-bottom-tab-panels child ext-panels))))]))

;; Rebuild the menu with extension menu items merged in
(define (rebuild-menu!)
  (define ext-menus
    (apply append
           (for/list ([desc (in-list (list-extensions))])
             (extension-descriptor-menus desc))))
  (define merged-menu
    (if (null? ext-menus)
        app-menu
        (merge-extension-menus app-menu ext-menus)))
  (send-message! (make-message "menu:set" 'menu merged-menu)))

;; Merge extension menu items into the app menu.
;; Each ext-menu has 'menu (target submenu label) and item fields.
(define (merge-extension-menus menu ext-menus)
  (for/list ([submenu (in-list menu)])
    (define submenu-label (hash-ref submenu 'label ""))
    (define matching
      (filter (lambda (em) (string=? (hash-ref em 'menu "") submenu-label))
              ext-menus))
    (if (null? matching)
        submenu
        (hash-set submenu 'children
                  (append (hash-ref submenu 'children '())
                          (list (hasheq 'label "---"))  ;; separator
                          (for/list ([em (in-list matching)])
                            (hasheq 'label (hash-ref em 'label "")
                                    'shortcut (hash-ref em 'shortcut "")
                                    'action (hash-ref em 'action ""))))))))

;; ── Extension list cell updater ────────────────────────────
;; Call after any extension load/unload/reload to keep the
;; _extensions-list cell in sync with loaded extensions.
(define (update-extensions-list-cell!)
  (cell-set! '_extensions-list (extensions-list-snapshot)))

;; ── Menu ───────────────────────────────────────────────────
(define app-menu
  (list
   (hasheq 'label "File"
           'children
           (list
            (hasheq 'label "New" 'shortcut "Cmd+N" 'action "new-file")
            (hasheq 'label "Open..." 'shortcut "Cmd+O" 'action "open-file")
            (hasheq 'label "Save" 'shortcut "Cmd+S" 'action "save-file")
            (hasheq 'label "---")
            (hasheq 'label "Find in Project..." 'shortcut "Cmd+Shift+F" 'action "find-in-project")
            (hasheq 'label "---")
            (hasheq 'label "Settings..." 'shortcut "Cmd+," 'action "settings")))
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
    ;; Extension manager: open file dialog to load an extension
    [(string=? event-name "extension:load-dialog")
     (send-message! (make-message "dialog:open-file"
                                  'filterName "Racket files"
                                  'filterExtension "rkt"))]
    ;; Extension manager: unload an extension by ID
    [(string=? event-name "extension:unload-request")
     (define ext-id-str (message-ref msg 'id ""))
     (when (not (string=? ext-id-str ""))
       (with-handlers ([exn:fail?
                        (lambda (e)
                          (eprintf "Extension unload error: ~a\n" (exn-message e)))])
         (unload-extension! (string->symbol ext-id-str))
         (rebuild-layout!)
         (update-extensions-list-cell!)
         (cell-set! 'status (format "Unloaded extension: ~a" ext-id-str))))]
    ;; Search focus (Cmd+Shift+F from frontend)
    [(string=? event-name "project:search-focus")
     (cell-set! 'current-bottom-tab "search")]
    ;; Project search request
    [(string=? event-name "project:search")
     (define query (message-ref msg 'query ""))
     (define is-regex (message-ref msg 'regex #f))
     (define case-sensitive (message-ref msg 'caseSensitive #f))
     (when (not (string=? query ""))
       (send-message! (make-message "project:search"
                                    'root (cell-ref 'project-root)
                                    'query query
                                    'regex is-regex
                                    'caseSensitive case-sensitive)))]
    ;; Settings panel: open
    [(string=? event-name "settings:open")
     (send-message! (make-message "settings:open"))
     ;; Send current settings and theme list to the panel
     (send-message! (make-message "settings:current"
                                  'settings (current-settings)))
     (send-message! (make-message "theme:list"
                                  'themes (list-themes)))
     (cell-set! 'status "Settings")]
    ;; Settings panel: change a setting
    [(string=? event-name "settings:change")
     (define key (string->symbol (message-ref msg 'key "")))
     (define sub-key (message-ref msg 'subKey #f))
     (define value (message-ref msg 'value #f))
     (cond
       [(and sub-key (hash? (settings-ref key)))
        (define current (settings-ref key))
        (settings-set! key (hash-set current (string->symbol sub-key) value))]
       [else
        (settings-set! key value)])
     ;; Apply editor settings changes live
     (when (eq? key 'editor)
       (send-message! (make-message "editor:apply-settings"
                                    'settings (settings-ref 'editor))))
     ;; Send updated settings back to the panel
     (send-message! (make-message "settings:current"
                                  'settings (current-settings)))]
    ;; Keybinding: reset a single keybinding to its default
    [(string=? event-name "keybinding:reset")
     (define action (message-ref msg 'action ""))
     (when (not (string=? action ""))
       ;; Find the default shortcut for this action
       (for ([(shortcut act) (in-hash default-keybindings)])
         (when (equal? act action)
           (keybinding-set! shortcut action)))
       (send-keybindings-to-frontend!))]
    ;; Theme switching
    [(string=? event-name "theme:switch")
     (define theme-name (message-ref msg 'theme "Light"))
     (apply-theme! theme-name)
     (cell-set! '_current-theme theme-name)
     ;; Persist theme choice
     (settings-set! 'theme theme-name)]
    ;; Keybinding: frontend detected a shortcut and resolved it to an action
    [(string=? event-name "keybinding:action")
     (define action (message-ref msg 'action ""))
     (when (not (string=? action ""))
       ;; Route through the same menu action handler
       (handle-menu-action (make-message "menu:action" 'action action)))]
    ;; Keybinding: frontend requests to update a key mapping
    [(string=? event-name "keybinding:update")
     (define shortcut (message-ref msg 'shortcut ""))
     (define action (message-ref msg 'action ""))
     (when (and (not (string=? shortcut ""))
                (not (string=? action "")))
       (keybinding-set! shortcut action)
       (send-keybindings-to-frontend!))]
    [else
     ;; Check auto-handlers (from ui macro lambdas), then extension dispatch
     (define auto-handler (get-auto-handler event-name))
     (cond
       [auto-handler (auto-handler msg)]
       [else
        (define ext-handler (get-extension-handler event-name))
        (if ext-handler
            (ext-handler msg)
            (eprintf "Unknown event: ~a\n" event-name))])]))

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
    [(string=? action "find-in-project")
     (cell-set! 'current-bottom-tab "search")
     (send-message! (make-message "project:search-focus"))]
    [(string=? action "settings")
     (send-message! (make-message "settings:open"))
     (send-message! (make-message "settings:current"
                                  'settings (current-settings)))
     (send-message! (make-message "theme:list"
                                  'themes (list-themes)))
     (cell-set! 'status "Settings")]
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
    ;; Extension management
    [(string=? typ "extension:load")
     (define path (message-ref msg 'path ""))
     (when (not (string=? path ""))
       (with-handlers ([exn:fail?
                        (lambda (e)
                          (eprintf "Extension load error: ~a\n" (exn-message e))
                          (cell-set! 'status (format "Extension error: ~a" (exn-message e))))])
         (load-extension! path)
         (rebuild-layout!)
         (update-extensions-list-cell!)
         (cell-set! 'status (format "Loaded extension: ~a" path))))]
    [(string=? typ "extension:unload")
     (define ext-id-str (message-ref msg 'id ""))
     (when (not (string=? ext-id-str ""))
       (with-handlers ([exn:fail?
                        (lambda (e)
                          (eprintf "Extension unload error: ~a\n" (exn-message e)))])
         (unload-extension! (string->symbol ext-id-str))
         (rebuild-layout!)
         (update-extensions-list-cell!)
         (cell-set! 'status (format "Unloaded extension: ~a" ext-id-str))))]
    [(string=? typ "extension:reload")
     (define path (message-ref msg 'path ""))
     (when (not (string=? path ""))
       (with-handlers ([exn:fail?
                        (lambda (e)
                          (eprintf "Extension reload error: ~a\n" (exn-message e)))])
         (reload-extension! path)
         (rebuild-layout!)
         (update-extensions-list-cell!)
         (cell-set! 'status (format "Reloaded extension: ~a" path))))]
    ;; Dialog result: file picker returned a path (e.g. for extension loading)
    [(string=? typ "dialog:result")
     (define path (message-ref msg 'path #f))
     (when (and path (not (equal? path 'null)) (not (equal? path "null"))
                (string? path) (not (string=? path "")))
       (with-handlers ([exn:fail?
                        (lambda (e)
                          (eprintf "Extension load error: ~a\n" (exn-message e))
                          (cell-set! 'status (format "Extension error: ~a" (exn-message e))))])
         (load-extension! path)
         (rebuild-layout!)
         (update-extensions-list-cell!)
         (cell-set! 'status (format "Loaded extension: ~a" path))))]
    [(string=? typ "fs:change")
     (handle-fs-change msg)]
    [(string=? typ "settings:loaded")
     (define loaded (message-ref msg 'settings (hasheq)))
     (apply-loaded-settings! loaded)
     ;; Apply theme from settings
     (define theme-name (settings-ref 'theme "Light"))
     (apply-theme! theme-name)
     (cell-set! '_current-theme theme-name)]
    [(string=? typ "ping")
     (send-message! (make-message "pong"))]
    [else
     (eprintf "Unknown message type: ~a\n" typ)]))

;; ── Startup sequence ───────────────────────────────────────

;; Derive project root by walking up from the script's location looking for info.rkt
(let ()
  (define run-path (find-system-path 'run-file))
  (define dir (simplify-path (build-path run-path 'up 'up 'up)))
  (define root (find-project-root (path->string dir)))
  (cell-set! 'project-root root)
  (cell-set! '_project-name (project-collection-name root))
  (eprintf "Project root: ~a\n" root))

(register-all-cells!)
(send-keybindings-to-frontend!)
;; Apply saved theme (defaults to Light if no settings loaded yet)
(apply-theme! (settings-ref 'theme "Light"))
(send-message! (make-message "menu:set" 'menu app-menu))
(send-message! (make-message "layout:set" 'layout (assign-layout-ids initial-layout)))

;; Start REPL PTY
(start-repl)
(set! _last-repl-gen (repl-generation))

(send-message! (make-message "lifecycle:ready"))
(start-message-loop dispatch)
