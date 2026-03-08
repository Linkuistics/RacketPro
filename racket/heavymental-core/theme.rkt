#lang racket/base

(require "protocol.rkt")

(provide register-theme!
         get-theme
         list-themes
         apply-theme!
         light-theme
         dark-theme)

;; Theme registry: name → theme hasheq
(define _themes (make-hash))

;; ── Built-in themes ─────────────────────────────────────────────

(define light-theme
  (hasheq 'name "Light"
          'monaco-theme "vs"
          ;; Backgrounds
          'bg-primary       "#FFFFFF"
          'bg-secondary     "#F3F3F3"
          'bg-toolbar       "#F8F8F8"
          'bg-terminal      "#FFFFFF"
          ;; Foregrounds
          'fg-primary       "#333333"
          'fg-secondary     "#616161"
          'fg-muted         "#999999"
          ;; Accent
          'accent           "#007ACC"
          'accent-hover     "#0062A3"
          ;; Borders
          'border           "#D4D4D4"
          'border-strong    "#C0C0C0"
          'divider          "#D4D4D4"
          'divider-hover    "#007ACC"
          ;; Semantic
          'danger           "#D32F2F"
          ;; Sidebar
          'bg-sidebar       "#F8F8F8"
          'fg-sidebar       "#333333"
          'fg-sidebar-muted "#616161"
          'bg-sidebar-hover "#E8E8E8"
          'bg-sidebar-active "#D6EBFF"
          ;; Tabs
          'bg-tab-bar       "#EAEAEA"
          'bg-tab-hover     "#F0F0F0"
          'fg-tab           "#888888"
          'fg-tab-active    "#333333"
          ;; Panel Headers
          'bg-panel-header  "#F3F3F3"
          'fg-panel-header  "#616161"
          ;; Status Bar
          'bg-statusbar     "#E8E8E8"
          'fg-statusbar     "#616161"))

(define dark-theme
  (hasheq 'name "Dark"
          'monaco-theme "vs-dark"
          ;; Backgrounds
          'bg-primary       "#1E1E1E"
          'bg-secondary     "#181818"
          'bg-toolbar       "#252526"
          'bg-terminal      "#1E1E1E"
          ;; Foregrounds
          'fg-primary       "#D4D4D4"
          'fg-secondary     "#ABABAB"
          'fg-muted         "#6A6A6A"
          ;; Accent
          'accent           "#007ACC"
          'accent-hover     "#1A8AD4"
          ;; Borders
          'border           "#3C3C3C"
          'border-strong    "#505050"
          'divider          "#3C3C3C"
          'divider-hover    "#007ACC"
          ;; Semantic
          'danger           "#F44747"
          ;; Sidebar
          'bg-sidebar       "#252526"
          'fg-sidebar       "#CCCCCC"
          'fg-sidebar-muted "#8B8B8B"
          'bg-sidebar-hover "#2A2D2E"
          'bg-sidebar-active "#37373D"
          ;; Tabs
          'bg-tab-bar       "#252526"
          'bg-tab-hover     "#2D2D2D"
          'fg-tab           "#8B8B8B"
          'fg-tab-active    "#FFFFFF"
          ;; Panel Headers
          'bg-panel-header  "#252526"
          'fg-panel-header  "#ABABAB"
          ;; Status Bar
          'bg-statusbar     "#007ACC"
          'fg-statusbar     "#FFFFFF"))

;; Register built-in themes
(hash-set! _themes "Light" light-theme)
(hash-set! _themes "Dark" dark-theme)

;; ── Theme API ───────────────────────────────────────────────────

(define (register-theme! theme)
  (define name (hash-ref theme 'name ""))
  (when (not (string=? name ""))
    (hash-set! _themes name theme)))

(define (get-theme name)
  (hash-ref _themes name #f))

(define (list-themes)
  (hash-keys _themes))

;; Send theme:apply message to frontend with all CSS variables
(define (apply-theme! name)
  (define theme (get-theme name))
  (when theme
    (send-message! (make-message "theme:apply"
                                 'name name
                                 'variables theme))))
