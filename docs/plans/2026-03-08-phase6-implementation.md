# Phase 6: Polish + Distribution — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Take HeavyMental from feature-complete to shippable with theming, settings, multi-file projects, keyboard shortcuts, and macOS packaging.

**Architecture:** Three parallel tracks (settings+theming, projects, keybindings) executed concurrently via subagents, then a settings UI integration step, and finally packaging. Each track creates new Racket modules, Rust handlers, and frontend components following existing patterns (cells, JSON-RPC messages, Lit Web Components).

**Tech Stack:** Racket (rackunit for tests), Rust/Tauri v2 (serde_json, tauri-plugin-dialog), Lit Web Components + @preact/signals-core (no build step), CSS custom properties.

---

## Track 1: Settings Persistence + Theming

### Task 1: Settings persistence — Rust side

**Files:**
- Create: `src-tauri/src/settings.rs`
- Modify: `src-tauri/src/lib.rs`
- Modify: `src-tauri/src/bridge.rs`

**Step 1: Create `src-tauri/src/settings.rs`**

```rust
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;

/// Return the settings file path:
/// ~/Library/Application Support/com.linkuistics.heavymental/settings.json
pub fn settings_path() -> PathBuf {
    let mut path = dirs::data_dir().unwrap_or_else(|| PathBuf::from("."));
    path.push("com.linkuistics.heavymental");
    path.push("settings.json");
    path
}

/// Read settings from disk. Returns empty object if file doesn't exist.
pub fn read_settings() -> Value {
    let path = settings_path();
    match fs::read_to_string(&path) {
        Ok(contents) => serde_json::from_str(&contents).unwrap_or(json!({})),
        Err(_) => json!({}),
    }
}

/// Write settings to disk. Creates parent directories if needed.
pub fn write_settings(settings: &Value) -> Result<(), String> {
    let path = settings_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create settings directory: {e}"))?;
    }
    let contents = serde_json::to_string_pretty(settings)
        .map_err(|e| format!("Failed to serialize settings: {e}"))?;
    fs::write(&path, contents)
        .map_err(|e| format!("Failed to write settings: {e}"))?;
    Ok(())
}
```

**Step 2: Add `dirs` crate to Cargo.toml**

Add to `[dependencies]`:
```toml
dirs = "6"
```

**Step 3: Register `settings` module in `lib.rs`**

Add `mod settings;` after `mod pty;` (line 4).

**Step 4: Send settings to Racket on startup in `lib.rs`**

After the bridge is started (after `Some(Arc::new(b))` on line 135), send the saved settings:

```rust
// Send saved settings to Racket on startup
let startup_settings = crate::settings::read_settings();
if let Err(e) = b.send(serde_json::json!({
    "type": "settings:loaded",
    "settings": startup_settings,
})) {
    eprintln!("[settings] Failed to send settings to Racket: {e}");
}
```

Note: this must happen before the `Arc::new(b)` wrapping, so restructure as:
```rust
Ok(b) => {
    eprintln!("[bridge] Racket bridge started successfully");
    let startup_settings = crate::settings::read_settings();
    let _ = b.send(serde_json::json!({
        "type": "settings:loaded",
        "settings": startup_settings,
    }));
    Some(Arc::new(b))
}
```

**Step 5: Intercept `settings:save` in `bridge.rs`**

Add to `handle_intercepted_message` match arms (before the `_ => false` catch-all):

```rust
"settings:save" => {
    if let Some(settings) = msg.get("settings") {
        let settings = settings.clone();
        thread::spawn(move || {
            if let Err(e) = crate::settings::write_settings(&settings) {
                eprintln!("[settings] save error: {e}");
            } else {
                eprintln!("[settings] saved successfully");
            }
        });
    }
    true
}
```

**Step 6: Verify it compiles**

Run: `cd /Users/antony/Development/Linkuistics/MrRacket && cargo build -p heavy-mental 2>&1 | tail -5`
Expected: Build succeeds.

**Step 7: Commit**

```bash
git add src-tauri/src/settings.rs src-tauri/src/lib.rs src-tauri/src/bridge.rs src-tauri/Cargo.toml
git commit -m "feat: add settings persistence (Rust side)"
```

### Task 2: Settings persistence — Racket side

**Files:**
- Create: `racket/heavymental-core/settings.rkt`
- Create: `test/test-settings.rkt`
- Modify: `racket/heavymental-core/main.rkt`

**Step 1: Create `racket/heavymental-core/settings.rkt`**

```racket
#lang racket/base

(require json racket/path "protocol.rkt")

(provide current-settings
         settings-ref
         settings-set!
         apply-loaded-settings!
         save-settings!
         load-project-settings!)

;; Internal settings hash — merged from defaults + global + project
(define _settings (make-hasheq))

;; Default settings
(define _defaults
  (hasheq 'theme "Light"
          'editor (hasheq 'fontFamily "SF Mono"
                          'fontSize 13
                          'fontWeight 300
                          'vimMode #f
                          'tabSize 2
                          'wordWrap #f
                          'minimap #f
                          'lineNumbers #t)
          'keybindings (hasheq)
          'window (hasheq 'width 1200 'height 800)
          'recentFiles '()))

;; Get the full settings hash
(define (current-settings)
  _settings)

;; Get a top-level setting by key symbol
(define (settings-ref key [default #f])
  (hash-ref _settings key default))

;; Set a top-level setting and trigger save
(define (settings-set! key value)
  (hash-set! _settings key value)
  (save-settings!))

;; Deep-merge: overlay wins over base for each key.
;; Both should be hasheqs.
(define (deep-merge base overlay)
  (define result (hash-copy base))
  (for ([(k v) (in-hash overlay)])
    (cond
      [(and (hash? v) (hash? (hash-ref result k #f)))
       (hash-set! result k (deep-merge (hash-ref result k) v))]
      [else
       (hash-set! result k v)]))
  result)

;; Apply settings received from Rust (settings:loaded message).
;; Merges defaults with loaded settings.
(define (apply-loaded-settings! loaded-hash)
  (set! _settings (deep-merge (hash-copy _defaults) loaded-hash)))

;; Send current settings to Rust for persistence
(define (save-settings!)
  (send-message! (make-message "settings:save"
                               'settings _settings)))

;; Load per-project settings from .heavymental/settings.rkt
;; Returns a hasheq or empty hasheq if file doesn't exist.
(define (load-project-settings! project-root)
  (define settings-path
    (build-path project-root ".heavymental" "settings.rkt"))
  (cond
    [(file-exists? settings-path)
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (eprintf "Error loading project settings: ~a\n"
                                 (exn-message e))
                        (hasheq))])
       (dynamic-require settings-path 'project-settings))]
    [else (hasheq)]))
```

**Step 2: Write test for settings module**

Create `test/test-settings.rkt`:

```racket
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
  (define msgs '())
  (parameterize ([current-output-port (open-output-nowhere)])
    (settings-set! 'theme "Solarized"))
  (check-equal? (settings-ref 'theme) "Solarized"))

;; ── Test: load-project-settings! with missing file ──────────────────

(test-case "load-project-settings! returns empty hash for missing file"
  (define result (load-project-settings! "/tmp/nonexistent-project-12345"))
  (check-true (hash? result))
  (check-equal? (hash-count result) 0))

(displayln "All settings tests passed.")
```

**Step 3: Run the test**

Run: `racket test/test-settings.rkt`
Expected: "All settings tests passed."

**Step 4: Wire settings into main.rkt**

Add to imports (after `"handler-registry.rkt"`):
```racket
"settings.rkt"
```

Add handler for `settings:loaded` in the `dispatch` function (before the `[(string=? typ "ping")` line):
```racket
[(string=? typ "settings:loaded")
 (define loaded (message-ref msg 'settings (hasheq)))
 (apply-loaded-settings! loaded)
 ;; Apply theme from settings
 (define theme-name (settings-ref 'theme "Light"))
 (send-message! (make-message "event" 'name "theme:switch" 'theme theme-name))]
```

**Step 5: Commit**

```bash
git add racket/heavymental-core/settings.rkt test/test-settings.rkt racket/heavymental-core/main.rkt
git commit -m "feat: add settings persistence (Racket side)"
```

### Task 3: Theme system — Racket side

**Files:**
- Create: `racket/heavymental-core/theme.rkt`
- Create: `test/test-theme.rkt`
- Modify: `racket/heavymental-core/main.rkt`

**Step 1: Create `racket/heavymental-core/theme.rkt`**

```racket
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
```

**Step 2: Write theme tests**

Create `test/test-theme.rkt`:

```racket
#lang racket/base

(require rackunit
         racket/port
         "../racket/heavymental-core/theme.rkt")

(test-case "built-in themes are registered"
  (define themes (list-themes))
  (check-true (member "Light" themes))
  (check-true (member "Dark" themes)))

(test-case "get-theme returns theme hash"
  (define light (get-theme "Light"))
  (check-true (hash? light))
  (check-equal? (hash-ref light 'name) "Light")
  (check-equal? (hash-ref light 'bg-primary) "#FFFFFF")
  (check-equal? (hash-ref light 'monaco-theme) "vs"))

(test-case "get-theme returns #f for unknown theme"
  (check-false (get-theme "Nonexistent")))

(test-case "dark theme has correct values"
  (define dark (get-theme "Dark"))
  (check-equal? (hash-ref dark 'bg-primary) "#1E1E1E")
  (check-equal? (hash-ref dark 'fg-primary) "#D4D4D4")
  (check-equal? (hash-ref dark 'monaco-theme) "vs-dark"))

(test-case "register-theme! adds a custom theme"
  (define custom (hasheq 'name "Solarized"
                         'bg-primary "#002B36"
                         'fg-primary "#839496"))
  (register-theme! custom)
  (check-true (member "Solarized" (list-themes)))
  (check-equal? (hash-ref (get-theme "Solarized") 'bg-primary) "#002B36"))

(test-case "apply-theme! sends message for valid theme"
  (define output
    (with-output-to-string
      (lambda () (apply-theme! "Light"))))
  (check-true (string-contains? output "theme:apply")))

(test-case "apply-theme! does nothing for unknown theme"
  (define output
    (with-output-to-string
      (lambda () (apply-theme! "DoesNotExist"))))
  (check-equal? output ""))

(displayln "All theme tests passed.")
```

**Step 3: Run the test**

Run: `racket test/test-theme.rkt`
Expected: "All theme tests passed."

**Step 4: Wire theme into main.rkt**

Add to imports: `"theme.rkt"`

Add `_current-theme` cell after existing cells:
```racket
(define-cell _current-theme "Light")
```

Add theme event handlers in `handle-event` (before the `[else` fallback):
```racket
[(string=? event-name "theme:switch")
 (define theme-name (message-ref msg 'theme "Light"))
 (apply-theme! theme-name)
 (cell-set! '_current-theme theme-name)
 ;; Persist theme choice
 (settings-set! 'theme theme-name)]
```

In the startup sequence (after `register-all-cells!` but before `send-message! menu:set`), apply the theme:
```racket
;; Apply saved theme (defaults to Light if no settings loaded yet)
(apply-theme! (settings-ref 'theme "Light"))
```

**Step 5: Commit**

```bash
git add racket/heavymental-core/theme.rkt test/test-theme.rkt racket/heavymental-core/main.rkt
git commit -m "feat: add Racket-driven theme system with light/dark themes"
```

### Task 4: Theme application — Frontend side

**Files:**
- Create: `frontend/core/theme.js`
- Modify: `frontend/core/main.js`

**Step 1: Create `frontend/core/theme.js`**

```javascript
// theme.js — Apply Racket-driven themes to CSS custom properties
//
// Listens for "theme:apply" messages from Racket. Each message contains
// a map of CSS custom property names (without '--' prefix) to values.
// Updates document.documentElement.style and syncs Monaco editor theme.

import { onMessage } from './bridge.js';

// Keys in the theme hash that are NOT CSS variables
const NON_CSS_KEYS = new Set(['name', 'monaco-theme']);

/**
 * Apply a theme's CSS variables to the document root.
 * @param {Object} variables — theme hash with property names and values
 */
function applyCssVariables(variables) {
  const root = document.documentElement;
  for (const [key, value] of Object.entries(variables)) {
    if (NON_CSS_KEYS.has(key)) continue;
    root.style.setProperty(`--${key}`, value);
  }
}

/**
 * Set the Monaco editor theme.
 * @param {string} monacoTheme — "vs" or "vs-dark"
 */
function applyMonacoTheme(monacoTheme) {
  if (window.monaco?.editor) {
    window.monaco.editor.setTheme(monacoTheme);
  }
}

/**
 * Initialise theme message handlers.
 */
export function initTheme() {
  onMessage('theme:apply', (msg) => {
    const variables = msg.variables || {};
    const monacoTheme = variables['monaco-theme'] || 'vs';

    applyCssVariables(variables);
    applyMonacoTheme(monacoTheme);

    console.log(`[theme] Applied theme: ${variables.name || 'unknown'}`);
  });
}
```

**Step 2: Wire into main.js**

Add import after existing imports:
```javascript
import { initTheme } from './theme.js';
```

Add `initTheme()` call after `initComponentRegistry()` (after "4.5/5"):
```javascript
initTheme();
console.log('[boot] 4.6/5 theme system initialised');
```

**Step 3: Commit**

```bash
git add frontend/core/theme.js frontend/core/main.js
git commit -m "feat: add frontend theme application (CSS variables + Monaco)"
```

---

## Track 2: Multi-File Projects

### Task 5: Project detection — Racket side

**Files:**
- Create: `racket/heavymental-core/project.rkt`
- Create: `test/test-project.rkt`
- Modify: `racket/heavymental-core/main.rkt`

**Step 1: Create `racket/heavymental-core/project.rkt`**

```racket
#lang racket/base

(require racket/path racket/list)

(provide find-project-root
         read-info-rkt
         project-collection-name)

;; Walk up from `start-path` looking for a directory containing `info.rkt`.
;; Returns the directory path string if found, or the parent of start-path.
(define (find-project-root start-path)
  (define start (if (file-exists? start-path)
                    (path-only start-path)
                    (string->path start-path)))
  (let loop ([dir (simplify-path start)])
    (define info (build-path dir "info.rkt"))
    (cond
      [(file-exists? info) (path->string dir)]
      [else
       (define parent (simplify-path (build-path dir 'up)))
       (cond
         [(equal? dir parent)
          ;; Reached filesystem root — fall back to start dir
          (path->string start)]
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
```

**Step 2: Write project tests**

Create `test/test-project.rkt`:

```racket
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
```

**Step 3: Run the test**

Run: `racket test/test-project.rkt`
Expected: "All project tests passed."

**Step 4: Wire project detection into main.rkt**

Add import: `"project.rkt"`

Add `_project-name` cell:
```racket
(define-cell _project-name "")
```

Update the startup project-root derivation (replace lines 579-584) to use `find-project-root`:
```racket
(let ()
  (define run-path (find-system-path 'run-file))
  (define dir (simplify-path (build-path run-path 'up 'up 'up)))
  (define root (find-project-root (path->string dir)))
  (cell-set! 'project-root root)
  (cell-set! '_project-name (project-collection-name root))
  (eprintf "Project root: ~a\n" root))
```

**Step 5: Commit**

```bash
git add racket/heavymental-core/project.rkt test/test-project.rkt racket/heavymental-core/main.rkt
git commit -m "feat: add project detection with info.rkt support"
```

### Task 6: Find-in-project search — Rust side

**Files:**
- Create: `src-tauri/src/search.rs`
- Modify: `src-tauri/src/bridge.rs`
- Modify: `src-tauri/Cargo.toml`

**Step 1: Add dependencies to Cargo.toml**

```toml
ignore = "0.4"
grep-regex = "0.1"
grep-searcher = "0.1"
grep-matcher = "0.1"
```

Note: If `grep-*` crates are unavailable or too complex, use a simpler approach — walk files with `ignore` crate (which handles .gitignore) and search each file with Rust's built-in regex.

Alternative simpler approach with just `ignore` + `regex`:
```toml
ignore = "0.4"
regex = "1"
```

**Step 2: Create `src-tauri/src/search.rs`**

```rust
use ignore::WalkBuilder;
use regex::Regex;
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

/// Search files in `root` matching `query`.
/// Returns a JSON array of matches.
pub fn search_project(
    root: &str,
    query: &str,
    is_regex: bool,
    case_sensitive: bool,
    file_glob: Option<&str>,
    exclude_dirs: &[String],
) -> Value {
    let pattern = if is_regex {
        if case_sensitive {
            Regex::new(query)
        } else {
            Regex::new(&format!("(?i){query}"))
        }
    } else {
        let escaped = regex::escape(query);
        if case_sensitive {
            Regex::new(&escaped)
        } else {
            Regex::new(&format!("(?i){escaped}"))
        }
    };

    let re = match pattern {
        Ok(re) => re,
        Err(e) => {
            return json!({
                "error": format!("Invalid search pattern: {e}")
            });
        }
    };

    let mut results: Vec<Value> = Vec::new();
    let max_results = 500; // Prevent overwhelming the frontend

    let mut walker = WalkBuilder::new(root);
    walker.hidden(true)  // skip hidden by default
          .git_ignore(true)
          .git_global(true);

    // Add custom exclude directories
    let mut overrides = ignore::overrides::OverrideBuilder::new(root);
    for dir in exclude_dirs {
        let _ = overrides.add(&format!("!{dir}/"));
    }
    if let Some(glob) = file_glob {
        let _ = overrides.add(glob);
    }
    if let Ok(built) = overrides.build() {
        walker.overrides(built);
    }

    for entry in walker.build() {
        if results.len() >= max_results {
            break;
        }

        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };

        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        // Skip binary files
        let content = match fs::read_to_string(path) {
            Ok(c) => c,
            Err(_) => continue,
        };

        for (line_num, line) in content.lines().enumerate() {
            if results.len() >= max_results {
                break;
            }

            if re.is_match(line) {
                results.push(json!({
                    "file": path.to_string_lossy(),
                    "line": line_num + 1,
                    "text": line.trim(),
                    "col": re.find(line).map(|m| m.start()).unwrap_or(0),
                }));
            }
        }
    }

    json!({
        "results": results,
        "truncated": results.len() >= max_results,
    })
}
```

**Step 3: Register module and intercept message in bridge.rs**

Add `mod search;` in `lib.rs`.

Add to `handle_intercepted_message` in `bridge.rs`:

```rust
"project:search" => {
    let root = msg.get("root").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let query = msg.get("query").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let is_regex = msg.get("regex").and_then(|v| v.as_bool()).unwrap_or(false);
    let case_sensitive = msg.get("caseSensitive").and_then(|v| v.as_bool()).unwrap_or(false);
    let file_glob = msg.get("glob").and_then(|v| v.as_str()).map(String::from);
    let exclude_dirs: Vec<String> = msg.get("excludeDirs")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
        .unwrap_or_else(|| vec![
            ".git".into(), "compiled".into(), "node_modules".into(), ".heavymental".into()
        ]);

    let tx = tx.clone();
    thread::spawn(move || {
        let results = crate::search::search_project(
            &root,
            &query,
            is_regex,
            case_sensitive,
            file_glob.as_deref(),
            &exclude_dirs,
        );
        let _ = tx.send(json!({
            "type": "project:search:results",
            "results": results.get("results").cloned().unwrap_or(json!([])),
            "truncated": results.get("truncated").and_then(|v| v.as_bool()).unwrap_or(false),
        }));
    });
    true
}
```

**Step 4: Verify it compiles**

Run: `cd /Users/antony/Development/Linkuistics/MrRacket && cargo build -p heavy-mental 2>&1 | tail -5`

**Step 5: Commit**

```bash
git add src-tauri/src/search.rs src-tauri/src/lib.rs src-tauri/src/bridge.rs src-tauri/Cargo.toml
git commit -m "feat: add project-wide file search (Rust side)"
```

### Task 7: Search panel — Frontend

**Files:**
- Create: `frontend/core/primitives/search-panel.js`
- Modify: `frontend/core/main.js`
- Modify: `racket/heavymental-core/main.rkt` (add SEARCH tab + Cmd+Shift+F)

**Step 1: Create `frontend/core/primitives/search-panel.js`**

```javascript
// search-panel.js — Find-in-project search results panel
import { LitElement, html, css } from 'lit';
import { onMessage, dispatch } from '../bridge.js';

export class HmSearchPanel extends LitElement {
  static properties = {
    results: { type: Array },
    query: { type: String },
    searching: { type: Boolean },
    truncated: { type: Boolean },
    useRegex: { type: Boolean },
    caseSensitive: { type: Boolean },
  };

  static styles = css`
    :host {
      display: flex;
      flex-direction: column;
      height: 100%;
      background: var(--bg-primary, #fff);
      color: var(--fg-primary, #333);
      font-family: var(--font-sans);
      font-size: 13px;
    }
    .search-bar {
      display: flex;
      gap: 4px;
      padding: 6px 8px;
      border-bottom: 1px solid var(--border, #d4d4d4);
      background: var(--bg-toolbar, #f8f8f8);
      align-items: center;
    }
    .search-bar input {
      flex: 1;
      padding: 3px 6px;
      border: 1px solid var(--border, #d4d4d4);
      border-radius: 3px;
      font-family: var(--font-mono);
      font-size: 12px;
      background: var(--bg-primary, #fff);
      color: var(--fg-primary, #333);
      outline: none;
    }
    .search-bar input:focus {
      border-color: var(--accent, #007acc);
    }
    .search-bar button {
      padding: 2px 6px;
      border: 1px solid var(--border, #d4d4d4);
      border-radius: 3px;
      background: var(--bg-primary, #fff);
      color: var(--fg-secondary, #616161);
      cursor: pointer;
      font-size: 11px;
    }
    .search-bar button.active {
      background: var(--accent, #007acc);
      color: #fff;
      border-color: var(--accent, #007acc);
    }
    .results {
      flex: 1;
      overflow-y: auto;
      padding: 0;
    }
    .file-group {
      margin: 0;
    }
    .file-header {
      padding: 3px 8px;
      font-weight: 600;
      font-size: 12px;
      color: var(--fg-secondary, #616161);
      background: var(--bg-secondary, #f3f3f3);
      border-bottom: 1px solid var(--border, #d4d4d4);
      cursor: default;
    }
    .match-row {
      display: flex;
      gap: 8px;
      padding: 2px 8px 2px 20px;
      cursor: pointer;
      border-bottom: 1px solid transparent;
    }
    .match-row:hover {
      background: var(--bg-sidebar-hover, #e8e8e8);
    }
    .line-num {
      color: var(--fg-muted, #999);
      min-width: 40px;
      text-align: right;
      font-family: var(--font-mono);
      font-size: 12px;
    }
    .match-text {
      font-family: var(--font-mono);
      font-size: 12px;
      white-space: pre;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .status {
      padding: 4px 8px;
      font-size: 11px;
      color: var(--fg-muted, #999);
      border-top: 1px solid var(--border, #d4d4d4);
    }
    .empty {
      padding: 20px;
      text-align: center;
      color: var(--fg-muted, #999);
    }
  `;

  constructor() {
    super();
    this.results = [];
    this.query = '';
    this.searching = false;
    this.truncated = false;
    this.useRegex = false;
    this.caseSensitive = false;

    onMessage('project:search:results', (msg) => {
      this.results = msg.results || [];
      this.truncated = msg.truncated || false;
      this.searching = false;
    });

    // Focus the search input when requested
    onMessage('project:search-focus', () => {
      this._focusInput();
    });
  }

  _focusInput() {
    requestAnimationFrame(() => {
      const input = this.shadowRoot?.querySelector('input');
      if (input) input.focus();
    });
  }

  _onKeyDown(e) {
    if (e.key === 'Enter') {
      this._doSearch();
    }
  }

  _onInput(e) {
    this.query = e.target.value;
  }

  _doSearch() {
    if (!this.query.trim()) return;
    this.searching = true;
    this.results = [];
    dispatch('project:search', {
      query: this.query,
      regex: this.useRegex,
      caseSensitive: this.caseSensitive,
    });
  }

  _toggleRegex() {
    this.useRegex = !this.useRegex;
  }

  _toggleCase() {
    this.caseSensitive = !this.caseSensitive;
  }

  _gotoResult(result) {
    dispatch('editor:goto-file', {
      path: result.file,
      line: result.line,
      col: result.col,
    });
  }

  _groupByFile() {
    const groups = new Map();
    for (const r of this.results) {
      if (!groups.has(r.file)) groups.set(r.file, []);
      groups.get(r.file).push(r);
    }
    return groups;
  }

  render() {
    const groups = this._groupByFile();

    return html`
      <div class="search-bar">
        <input
          type="text"
          placeholder="Search in project..."
          .value=${this.query}
          @input=${this._onInput}
          @keydown=${this._onKeyDown}
        />
        <button
          class=${this.useRegex ? 'active' : ''}
          @click=${this._toggleRegex}
          title="Use Regular Expression"
        >.*</button>
        <button
          class=${this.caseSensitive ? 'active' : ''}
          @click=${this._toggleCase}
          title="Match Case"
        >Aa</button>
      </div>
      <div class="results">
        ${this.searching ? html`<div class="empty">Searching...</div>` : ''}
        ${!this.searching && this.results.length === 0 && this.query
          ? html`<div class="empty">No results found</div>`
          : ''}
        ${[...groups.entries()].map(([file, matches]) => html`
          <div class="file-group">
            <div class="file-header">${file.split('/').pop()} — ${file}</div>
            ${matches.map(m => html`
              <div class="match-row" @click=${() => this._gotoResult(m)}>
                <span class="line-num">${m.line}</span>
                <span class="match-text">${m.text}</span>
              </div>
            `)}
          </div>
        `)}
      </div>
      ${this.results.length > 0 ? html`
        <div class="status">
          ${this.results.length} results${this.truncated ? ' (truncated)' : ''}
        </div>
      ` : ''}
    `;
  }
}

customElements.define('hm-search-panel', HmSearchPanel);
```

**Step 2: Import in main.js**

Add after existing primitive imports:
```javascript
import './primitives/search-panel.js';
```

**Step 3: Add SEARCH tab and Cmd+Shift+F to main.rkt**

In `initial-layout`, add SEARCH tab to the bottom-tabs list (after the `extensions` tab entry):
```racket
(hasheq 'id "search" 'label "Search")
```

Add search panel to tab-content children (after the extension-manager entry):
```racket
(hasheq 'type "search-panel"
        'props (hasheq 'data-tab-id "search")
        'children (list))
```

Add Cmd+Shift+F handler in `handle-event`:
```racket
[(string=? event-name "project:search-focus")
 (cell-set! 'current-bottom-tab "search")]
```

Add Cmd+Shift+F to the File menu in `app-menu`:
```racket
(hasheq 'label "Find in Project..." 'shortcut "Cmd+Shift+F" 'action "find-in-project")
```

Add menu action handler in `handle-menu-action`:
```racket
[(string=? action "find-in-project")
 (cell-set! 'current-bottom-tab "search")
 (send-message! (make-message "project:search-focus"))]
```

Add `project:search` event handler in `handle-event`:
```racket
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
```

**Step 4: Commit**

```bash
git add frontend/core/primitives/search-panel.js frontend/core/main.js racket/heavymental-core/main.rkt
git commit -m "feat: add find-in-project search panel with Cmd+Shift+F"
```

---

## Track 3: Keyboard Shortcuts

### Task 8: Keybinding registry — Racket side

**Files:**
- Create: `racket/heavymental-core/keybindings.rkt`
- Create: `test/test-keybindings.rkt`
- Modify: `racket/heavymental-core/main.rkt`

**Step 1: Create `racket/heavymental-core/keybindings.rkt`**

```racket
#lang racket/base

(require racket/list "protocol.rkt")

(provide default-keybindings
         keybinding-ref
         keybinding-set!
         all-keybindings
         apply-keybinding-overrides!
         send-keybindings-to-frontend!
         action-for-shortcut)

;; Default keybindings: shortcut → action
(define default-keybindings
  (hasheq "Cmd+N" "new-file"
          "Cmd+O" "open-file"
          "Cmd+S" "editor:save-request"
          "Cmd+R" "run"
          "Cmd+," "settings:open"
          "Cmd+Shift+F" "find-in-project"
          "Cmd+Shift+R" "step-through"
          "Cmd+Shift+E" "expand-macros"))

;; Active keybindings (defaults + overrides)
(define _keybindings (make-hash))

;; Initialize with defaults
(for ([(k v) (in-hash default-keybindings)])
  (hash-set! _keybindings k v))

;; Get action for a shortcut
(define (keybinding-ref shortcut)
  (hash-ref _keybindings shortcut #f))

;; Set a keybinding (shortcut → action)
(define (keybinding-set! shortcut action)
  (hash-set! _keybindings shortcut action))

;; Get all active keybindings as an immutable hash
(define (all-keybindings)
  (for/hasheq ([(k v) (in-hash _keybindings)])
    (values k v)))

;; Look up action by shortcut
(define (action-for-shortcut shortcut)
  (hash-ref _keybindings shortcut #f))

;; Apply user overrides from settings.
;; overrides is a hasheq of action → shortcut (reversed mapping).
(define (apply-keybinding-overrides! overrides)
  ;; Reset to defaults first
  (hash-clear! _keybindings)
  (for ([(k v) (in-hash default-keybindings)])
    (hash-set! _keybindings k v))
  ;; Apply overrides: remove old shortcut for action, add new one
  (for ([(action new-shortcut) (in-hash overrides)])
    ;; Remove any existing binding for this action
    (for ([(shortcut act) (in-hash _keybindings)])
      (when (equal? act action)
        (hash-remove! _keybindings shortcut)))
    ;; Add the new binding
    (hash-set! _keybindings new-shortcut action)))

;; Send the active keymap to the frontend
(define (send-keybindings-to-frontend!)
  (send-message! (make-message "keybindings:set"
                               'keybindings (all-keybindings))))
```

**Step 2: Write keybinding tests**

Create `test/test-keybindings.rkt`:

```racket
#lang racket/base

(require rackunit
         racket/port
         "../racket/heavymental-core/keybindings.rkt")

(test-case "default keybindings are registered"
  (check-equal? (keybinding-ref "Cmd+S") "editor:save-request")
  (check-equal? (keybinding-ref "Cmd+R") "run")
  (check-equal? (keybinding-ref "Cmd+,") "settings:open"))

(test-case "keybinding-ref returns #f for unknown shortcut"
  (check-false (keybinding-ref "Cmd+Z+Z+Z")))

(test-case "keybinding-set! updates a binding"
  (keybinding-set! "Cmd+Shift+X" "custom-action")
  (check-equal? (keybinding-ref "Cmd+Shift+X") "custom-action")
  ;; Cleanup
  (apply-keybinding-overrides! (hasheq)))

(test-case "apply-keybinding-overrides! remaps actions"
  (apply-keybinding-overrides!
   (hasheq "run" "Cmd+Shift+R2"))
  ;; Old shortcut should no longer map to "run"
  (check-false (equal? (keybinding-ref "Cmd+R") "run"))
  ;; New shortcut should map to "run"
  (check-equal? (keybinding-ref "Cmd+Shift+R2") "run")
  ;; Reset
  (apply-keybinding-overrides! (hasheq)))

(test-case "all-keybindings returns a hash"
  (define kb (all-keybindings))
  (check-true (hash? kb))
  (check-true (> (hash-count kb) 0)))

(test-case "action-for-shortcut works"
  (check-equal? (action-for-shortcut "Cmd+R") "run"))

(test-case "send-keybindings-to-frontend! sends message"
  (define output
    (with-output-to-string
      (lambda () (send-keybindings-to-frontend!))))
  (check-true (string-contains? output "keybindings:set")))

(displayln "All keybinding tests passed.")
```

**Step 3: Run the test**

Run: `racket test/test-keybindings.rkt`
Expected: "All keybinding tests passed."

**Step 4: Wire keybindings into main.rkt**

Add import: `"keybindings.rkt"`

Add `keybinding:action` handler in `handle-event`:
```racket
[(string=? event-name "keybinding:action")
 (define action (message-ref msg 'action ""))
 (when (not (string=? action ""))
   ;; Route through the same menu action handler
   (handle-menu-action (make-message "menu:action" 'action action)))]
```

Add `keybinding:set` handler in `handle-event` (for frontend requesting keymap changes):
```racket
[(string=? event-name "keybinding:update")
 (define shortcut (message-ref msg 'shortcut ""))
 (define action (message-ref msg 'action ""))
 (when (and (not (string=? shortcut ""))
            (not (string=? action "")))
   (keybinding-set! shortcut action)
   (send-keybindings-to-frontend!)
   ;; Persist to settings
   (define kb-overrides (hasheq))
   ;; Build action→shortcut map for non-default bindings
   ;; (handled by settings UI, saved via settings:save)
   )]
```

In startup sequence, after `register-all-cells!`:
```racket
(send-keybindings-to-frontend!)
```

**Step 5: Commit**

```bash
git add racket/heavymental-core/keybindings.rkt test/test-keybindings.rkt racket/heavymental-core/main.rkt
git commit -m "feat: add keybinding registry with customization support"
```

### Task 9: Frontend keydown handler

**Files:**
- Create: `frontend/core/keybindings.js`
- Modify: `frontend/core/main.js`

**Step 1: Create `frontend/core/keybindings.js`**

```javascript
// keybindings.js — Global keyboard shortcut handler
//
// Receives the active keymap from Racket via "keybindings:set" messages.
// Captures keydown events that Monaco doesn't handle and dispatches
// the mapped action back to Racket.

import { onMessage, dispatch } from './bridge.js';

/** @type {Map<string, string>} shortcut → action */
const keymap = new Map();

/** @type {boolean} whether we're in recording mode (for keybinding editor) */
let recording = false;

/** @type {function|null} callback for recording mode */
let recordCallback = null;

/**
 * Convert a KeyboardEvent to a shortcut string like "Cmd+Shift+F".
 */
function eventToShortcut(e) {
  const parts = [];
  if (e.metaKey || e.ctrlKey) parts.push('Cmd');
  if (e.altKey) parts.push('Alt');
  if (e.shiftKey) parts.push('Shift');

  const key = e.key;
  // Skip modifier-only keys
  if (['Meta', 'Control', 'Alt', 'Shift'].includes(key)) return null;

  // Normalize key names
  const normalizedKey = key.length === 1 ? key.toUpperCase() : key;
  parts.push(normalizedKey);

  return parts.join('+');
}

/**
 * Initialise the keybinding system.
 */
export function initKeybindings() {
  // Receive keymap from Racket
  onMessage('keybindings:set', (msg) => {
    keymap.clear();
    const kb = msg.keybindings || {};
    for (const [shortcut, action] of Object.entries(kb)) {
      keymap.set(shortcut, action);
    }
    console.log(`[keybindings] Loaded ${keymap.size} keybindings`);
  });

  // Global keydown handler
  document.addEventListener('keydown', (e) => {
    // Recording mode for keybinding editor
    if (recording && recordCallback) {
      e.preventDefault();
      e.stopPropagation();
      const shortcut = eventToShortcut(e);
      if (shortcut) {
        recordCallback(shortcut);
        recording = false;
        recordCallback = null;
      }
      return;
    }

    const shortcut = eventToShortcut(e);
    if (!shortcut) return;

    const action = keymap.get(shortcut);
    if (action) {
      // Don't capture if focus is inside Monaco editor — let Monaco handle it
      // unless it's a shortcut Monaco wouldn't know about
      const activeEl = document.activeElement;
      const inMonaco = activeEl?.closest?.('.monaco-editor');

      // These shortcuts should always be captured (not editor-internal)
      const alwaysCapture = new Set([
        'settings:open', 'find-in-project', 'new-file', 'open-file',
        'run', 'step-through', 'expand-macros',
      ]);

      if (inMonaco && !alwaysCapture.has(action)) {
        return; // Let Monaco handle it
      }

      e.preventDefault();
      e.stopPropagation();
      dispatch('keybinding:action', { action });
    }
  }, true); // Use capture phase
}

/**
 * Start recording mode for the keybinding editor.
 * The next key combination will be passed to the callback.
 * @param {function} callback — receives the shortcut string
 */
export function startRecording(callback) {
  recording = true;
  recordCallback = callback;
}

/**
 * Cancel recording mode.
 */
export function cancelRecording() {
  recording = false;
  recordCallback = null;
}

/**
 * Get the current keymap for display in settings.
 * @returns {Map<string, string>}
 */
export function getKeymap() {
  return new Map(keymap);
}
```

**Step 2: Wire into main.js**

Add import:
```javascript
import { initKeybindings } from './keybindings.js';
```

Add after `initTheme()`:
```javascript
initKeybindings();
console.log('[boot] 4.7/5 keybindings initialised');
```

**Step 3: Commit**

```bash
git add frontend/core/keybindings.js frontend/core/main.js
git commit -m "feat: add frontend keybinding handler with recording mode"
```

### Task 10: Vim mode support

**Files:**
- Modify: `frontend/core/primitives/editor.js`

**Step 1: Vendor monaco-vim**

Download `monaco-vim` ESM bundle to `frontend/vendor/monaco-vim/`. This needs to be sourced manually — check npm registry for a pre-built ESM. If unavailable as a clean ESM, we'll use a dynamic import approach.

Create a placeholder that can be replaced with the actual vendored file:
```javascript
// frontend/vendor/monaco-vim/index.js
// Placeholder — replace with actual monaco-vim ESM bundle
// See: https://github.com/brijeshb42/monaco-vim
export function initVimMode(editor, statusElement) {
  console.warn('[vim] monaco-vim not yet vendored');
  return { dispose() {} };
}
```

**Step 2: Add vim mode toggle to editor.js**

In the editor component, add:
- A `vimMode` property
- An `onMessage('editor:set-vim-mode')` handler
- Vim mode initialization/disposal logic

Add to the editor component's properties:
```javascript
vimMode: { type: Boolean, state: true },
```

Add vim mode handler in the constructor or `connectedCallback`:
```javascript
onMessage('editor:set-vim-mode', (msg) => {
  this.vimMode = msg.enabled;
  if (this._editor) {
    if (this.vimMode) {
      this._enableVim();
    } else {
      this._disableVim();
    }
  }
});
```

Add vim methods:
```javascript
async _enableVim() {
  if (this._vimMode) return;
  try {
    const { initVimMode } = await import('../../vendor/monaco-vim/index.js');
    // Create a status bar element for vim mode indicator
    let statusEl = this.shadowRoot.querySelector('.vim-status');
    if (!statusEl) {
      statusEl = document.createElement('div');
      statusEl.className = 'vim-status';
      this.shadowRoot.appendChild(statusEl);
    }
    this._vimMode = initVimMode(this._editor, statusEl);
  } catch (e) {
    console.error('[editor] Failed to enable vim mode:', e);
  }
}

_disableVim() {
  if (this._vimMode) {
    this._vimMode.dispose();
    this._vimMode = null;
    const statusEl = this.shadowRoot.querySelector('.vim-status');
    if (statusEl) statusEl.textContent = '';
  }
}
```

Add CSS for vim status:
```css
.vim-status {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  height: 20px;
  background: var(--bg-statusbar, #e8e8e8);
  color: var(--fg-statusbar, #616161);
  font-family: var(--font-mono);
  font-size: 11px;
  padding: 2px 8px;
  display: none;
}
:host([vim-mode]) .vim-status {
  display: block;
}
```

**Step 3: Commit**

```bash
git add frontend/vendor/monaco-vim/index.js frontend/core/primitives/editor.js
git commit -m "feat: add vim mode support scaffold for Monaco editor"
```

---

## Integration: Settings UI Panel

### Task 11: Settings panel component

**Files:**
- Create: `frontend/core/primitives/settings-panel.js`
- Modify: `frontend/core/main.js`
- Modify: `racket/heavymental-core/main.rkt`

**Step 1: Create `frontend/core/primitives/settings-panel.js`**

This is the largest component. It provides sections for Appearance, Editor, Keybindings, and Project settings.

```javascript
// settings-panel.js — Visual settings editor
import { LitElement, html, css } from 'lit';
import { onMessage, dispatch } from '../bridge.js';
import { getKeymap, startRecording, cancelRecording } from '../keybindings.js';

export class HmSettingsPanel extends LitElement {
  static properties = {
    activeSection: { type: String },
    settings: { type: Object },
    themes: { type: Array },
    keybindings: { type: Object },
    recordingAction: { type: String },
    keybindingFilter: { type: String },
  };

  static styles = css`
    :host {
      display: flex;
      height: 100%;
      background: var(--bg-primary, #fff);
      color: var(--fg-primary, #333);
      font-family: var(--font-sans);
      font-size: 13px;
    }
    nav {
      width: 180px;
      border-right: 1px solid var(--border, #d4d4d4);
      background: var(--bg-secondary, #f3f3f3);
      padding: 12px 0;
    }
    nav button {
      display: block;
      width: 100%;
      padding: 6px 16px;
      border: none;
      background: transparent;
      color: var(--fg-primary, #333);
      text-align: left;
      cursor: pointer;
      font-size: 13px;
      font-family: var(--font-sans);
    }
    nav button:hover {
      background: var(--bg-sidebar-hover, #e8e8e8);
    }
    nav button.active {
      background: var(--bg-sidebar-active, #d6ebff);
      font-weight: 600;
    }
    .content {
      flex: 1;
      padding: 16px 24px;
      overflow-y: auto;
    }
    h2 {
      font-size: 18px;
      margin-bottom: 16px;
      font-weight: 600;
    }
    .setting-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 8px 0;
      border-bottom: 1px solid var(--border, #d4d4d4);
    }
    .setting-label {
      font-weight: 500;
    }
    .setting-desc {
      font-size: 11px;
      color: var(--fg-muted, #999);
      margin-top: 2px;
    }
    select, input[type="number"], input[type="text"] {
      padding: 4px 8px;
      border: 1px solid var(--border, #d4d4d4);
      border-radius: 3px;
      background: var(--bg-primary, #fff);
      color: var(--fg-primary, #333);
      font-size: 13px;
      font-family: var(--font-sans);
    }
    .toggle {
      position: relative;
      width: 36px;
      height: 20px;
      background: var(--border, #d4d4d4);
      border-radius: 10px;
      cursor: pointer;
      transition: background 0.2s;
    }
    .toggle.on {
      background: var(--accent, #007acc);
    }
    .toggle::after {
      content: '';
      position: absolute;
      top: 2px;
      left: 2px;
      width: 16px;
      height: 16px;
      background: white;
      border-radius: 50%;
      transition: transform 0.2s;
    }
    .toggle.on::after {
      transform: translateX(16px);
    }
    /* Keybinding editor styles */
    .kb-filter {
      width: 100%;
      margin-bottom: 12px;
      padding: 6px 8px;
    }
    .kb-table {
      width: 100%;
      border-collapse: collapse;
    }
    .kb-table th {
      text-align: left;
      padding: 6px 8px;
      border-bottom: 2px solid var(--border, #d4d4d4);
      font-weight: 600;
      font-size: 12px;
      color: var(--fg-secondary, #616161);
    }
    .kb-table td {
      padding: 4px 8px;
      border-bottom: 1px solid var(--border, #d4d4d4);
    }
    .kb-shortcut {
      cursor: pointer;
      padding: 2px 8px;
      border-radius: 3px;
      font-family: var(--font-mono);
      font-size: 12px;
      background: var(--bg-secondary, #f3f3f3);
      display: inline-block;
    }
    .kb-shortcut:hover {
      background: var(--bg-sidebar-hover, #e8e8e8);
    }
    .kb-shortcut.recording {
      background: var(--accent, #007acc);
      color: #fff;
      animation: pulse 1s infinite;
    }
    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.7; }
    }
    .kb-reset {
      border: none;
      background: transparent;
      color: var(--fg-muted, #999);
      cursor: pointer;
      font-size: 11px;
    }
    .kb-reset:hover {
      color: var(--danger, #d32f2f);
    }
  `;

  constructor() {
    super();
    this.activeSection = 'appearance';
    this.settings = {};
    this.themes = ['Light', 'Dark'];
    this.keybindings = {};
    this.recordingAction = null;
    this.keybindingFilter = '';

    // Listen for settings updates
    onMessage('settings:current', (msg) => {
      this.settings = msg.settings || {};
    });
    // Listen for theme list
    onMessage('theme:list', (msg) => {
      this.themes = msg.themes || ['Light', 'Dark'];
    });
  }

  _setSection(section) {
    this.activeSection = section;
  }

  _changeSetting(key, subKey, value) {
    if (subKey) {
      dispatch('settings:change', { key, subKey, value });
    } else {
      dispatch('settings:change', { key, value });
    }
  }

  _changeTheme(e) {
    const theme = e.target.value;
    dispatch('theme:switch', { theme });
  }

  _startRecordKeybinding(action) {
    this.recordingAction = action;
    startRecording((shortcut) => {
      this.recordingAction = null;
      dispatch('keybinding:update', { action, shortcut });
    });
  }

  _cancelRecording() {
    this.recordingAction = null;
    cancelRecording();
  }

  _resetKeybinding(action) {
    dispatch('keybinding:reset', { action });
  }

  _renderAppearance() {
    const theme = this.settings.theme || 'Light';
    const editor = this.settings.editor || {};

    return html`
      <h2>Appearance</h2>
      <div class="setting-row">
        <div>
          <div class="setting-label">Theme</div>
          <div class="setting-desc">Choose your color theme</div>
        </div>
        <select @change=${this._changeTheme}>
          ${this.themes.map(t => html`
            <option value=${t} ?selected=${t === theme}>${t}</option>
          `)}
        </select>
      </div>
      <div class="setting-row">
        <div>
          <div class="setting-label">Font Family</div>
          <div class="setting-desc">Editor font family</div>
        </div>
        <input type="text" .value=${editor.fontFamily || 'SF Mono'}
          @change=${(e) => this._changeSetting('editor', 'fontFamily', e.target.value)} />
      </div>
      <div class="setting-row">
        <div>
          <div class="setting-label">Font Size</div>
          <div class="setting-desc">Editor font size in pixels</div>
        </div>
        <input type="number" min="8" max="32" .value=${String(editor.fontSize || 13)}
          @change=${(e) => this._changeSetting('editor', 'fontSize', Number(e.target.value))} />
      </div>
    `;
  }

  _renderEditor() {
    const editor = this.settings.editor || {};

    return html`
      <h2>Editor</h2>
      <div class="setting-row">
        <div>
          <div class="setting-label">Vim Mode</div>
          <div class="setting-desc">Enable vim keybindings in the editor</div>
        </div>
        <div class="toggle ${editor.vimMode ? 'on' : ''}"
          @click=${() => this._changeSetting('editor', 'vimMode', !editor.vimMode)}></div>
      </div>
      <div class="setting-row">
        <div>
          <div class="setting-label">Tab Size</div>
        </div>
        <input type="number" min="1" max="8" .value=${String(editor.tabSize || 2)}
          @change=${(e) => this._changeSetting('editor', 'tabSize', Number(e.target.value))} />
      </div>
      <div class="setting-row">
        <div>
          <div class="setting-label">Word Wrap</div>
        </div>
        <div class="toggle ${editor.wordWrap ? 'on' : ''}"
          @click=${() => this._changeSetting('editor', 'wordWrap', !editor.wordWrap)}></div>
      </div>
      <div class="setting-row">
        <div>
          <div class="setting-label">Minimap</div>
        </div>
        <div class="toggle ${editor.minimap ? 'on' : ''}"
          @click=${() => this._changeSetting('editor', 'minimap', !editor.minimap)}></div>
      </div>
      <div class="setting-row">
        <div>
          <div class="setting-label">Line Numbers</div>
        </div>
        <div class="toggle ${editor.lineNumbers !== false ? 'on' : ''}"
          @click=${() => this._changeSetting('editor', 'lineNumbers', !(editor.lineNumbers !== false))}></div>
      </div>
    `;
  }

  _renderKeybindings() {
    const km = getKeymap();
    const entries = [...km.entries()]
      .filter(([shortcut, action]) => {
        if (!this.keybindingFilter) return true;
        const filter = this.keybindingFilter.toLowerCase();
        return action.toLowerCase().includes(filter) ||
               shortcut.toLowerCase().includes(filter);
      })
      .sort((a, b) => a[1].localeCompare(b[1]));

    return html`
      <h2>Keybindings</h2>
      <input class="kb-filter" type="text" placeholder="Filter keybindings..."
        .value=${this.keybindingFilter}
        @input=${(e) => { this.keybindingFilter = e.target.value; }} />
      <table class="kb-table">
        <thead>
          <tr><th>Action</th><th>Shortcut</th><th></th></tr>
        </thead>
        <tbody>
          ${entries.map(([shortcut, action]) => html`
            <tr>
              <td>${action}</td>
              <td>
                <span class="kb-shortcut ${this.recordingAction === action ? 'recording' : ''}"
                  @click=${() => this.recordingAction === action
                    ? this._cancelRecording()
                    : this._startRecordKeybinding(action)}>
                  ${this.recordingAction === action ? 'Press keys...' : shortcut}
                </span>
              </td>
              <td>
                <button class="kb-reset" @click=${() => this._resetKeybinding(action)}
                  title="Reset to default">Reset</button>
              </td>
            </tr>
          `)}
        </tbody>
      </table>
    `;
  }

  render() {
    const sections = [
      { id: 'appearance', label: 'Appearance' },
      { id: 'editor', label: 'Editor' },
      { id: 'keybindings', label: 'Keybindings' },
    ];

    return html`
      <nav>
        ${sections.map(s => html`
          <button class=${s.id === this.activeSection ? 'active' : ''}
            @click=${() => this._setSection(s.id)}>${s.label}</button>
        `)}
      </nav>
      <div class="content">
        ${this.activeSection === 'appearance' ? this._renderAppearance() : ''}
        ${this.activeSection === 'editor' ? this._renderEditor() : ''}
        ${this.activeSection === 'keybindings' ? this._renderKeybindings() : ''}
      </div>
    `;
  }
}

customElements.define('hm-settings-panel', HmSettingsPanel);
```

**Step 2: Import in main.js**

Add after existing primitive imports:
```javascript
import './primitives/settings-panel.js';
```

**Step 3: Add settings event handlers in main.rkt**

Add `settings:open` handler in `handle-event`:
```racket
[(string=? event-name "settings:open")
 ;; Open settings as a special editor tab
 (send-message! (make-message "settings:open"))
 (cell-set! 'status "Settings")]
```

Add `settings:change` handler:
```racket
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
                                'settings (settings-ref 'editor))))]
```

Add `settings:open` to the File menu:
```racket
(hasheq 'label "---")
(hasheq 'label "Settings..." 'shortcut "Cmd+," 'action "settings")
```

Add settings menu action handler:
```racket
[(string=? action "settings")
 (send-message! (make-message "settings:open"))]
```

**Step 4: Commit**

```bash
git add frontend/core/primitives/settings-panel.js frontend/core/main.js racket/heavymental-core/main.rkt
git commit -m "feat: add visual settings panel with appearance, editor, and keybinding sections"
```

---

## Packaging

### Task 12: Tauri bundle configuration

**Files:**
- Modify: `src-tauri/tauri.conf.json`
- Create: `src-tauri/icons/` (placeholder)
- Modify: `src-tauri/src/bridge.rs`

**Step 1: Update tauri.conf.json**

Replace the current contents with:
```json
{
  "$schema": "https://raw.githubusercontent.com/tauri-apps/tauri/dev/crates/tauri-cli/schema.json",
  "productName": "HeavyMental",
  "version": "0.1.0",
  "identifier": "com.linkuistics.heavymental",
  "build": {
    "frontendDist": "../frontend"
  },
  "app": {
    "withGlobalTauri": true,
    "windows": [
      {
        "title": "HeavyMental",
        "width": 1200,
        "height": 800
      }
    ]
  },
  "bundle": {
    "active": true,
    "targets": ["dmg", "app"],
    "icon": [
      "icons/32x32.png",
      "icons/128x128.png",
      "icons/128x128@2x.png",
      "icons/icon.icns",
      "icons/icon.ico"
    ],
    "category": "DeveloperTool",
    "copyright": "© 2026 Linkuistics",
    "shortDescription": "A Racket-driven IDE",
    "longDescription": "HeavyMental is a DrRacket-class IDE built on Tauri, where Racket is the orchestrator and the native app is a rendering surface.",
    "macOS": {
      "minimumSystemVersion": "13.0"
    }
  }
}
```

**Step 2: Generate placeholder icons**

Create a simple 1024x1024 PNG and use `cargo tauri icon` to generate all sizes. For now, create the directory:
```bash
mkdir -p src-tauri/icons
```

A proper app icon can be designed later and regenerated with `cargo tauri icon path/to/icon.png`.

**Step 3: Add Racket-not-found detection in bridge.rs**

In `RacketBridge::start()`, before the `Command::new("racket")` call, add a check:

```rust
// Check if racket is available on PATH
if Command::new("racket")
    .arg("--version")
    .stdout(Stdio::null())
    .stderr(Stdio::null())
    .status()
    .is_err()
{
    // Show dialog on main thread
    let app = app_handle.clone();
    let _ = app_handle.run_on_main_thread(move || {
        app.dialog()
            .message("Racket is required but was not found on your PATH.\n\nPlease install Racket from https://racket-lang.org and ensure the 'racket' command is available in your terminal.")
            .title("Racket Not Found")
            .kind(tauri_plugin_dialog::MessageDialogKind::Error)
            .blocking_show();
    });
    return Err("Racket not found on PATH".to_string());
}
```

Note: `RacketBridge::start` doesn't currently have `AppHandle` in a position to show dialogs easily from the thread. The check can alternatively be done in `lib.rs` `setup()` before calling `RacketBridge::start()`.

Better approach — add the check in `lib.rs` setup, before the bridge starts:

```rust
// Check for Racket before starting bridge
if std::process::Command::new("racket")
    .arg("--version")
    .stdout(std::process::Stdio::null())
    .stderr(std::process::Stdio::null())
    .status()
    .is_err()
{
    let dialog_app = app.handle().clone();
    dialog_app.dialog()
        .message("Racket is required but was not found on your PATH.\n\nPlease install Racket from https://racket-lang.org and ensure the 'racket' command is available in your terminal.")
        .title("Racket Not Found")
        .kind(tauri_plugin_dialog::MessageDialogKind::Error)
        .blocking_show();
    eprintln!("[bridge] Racket not found on PATH");
}
```

**Step 4: Commit**

```bash
git add src-tauri/tauri.conf.json src-tauri/src/lib.rs
git commit -m "feat: add macOS packaging config and Racket-not-found detection"
```

---

## Final Integration Test

### Task 13: Run all tests and verify

**Step 1: Run all existing tests**

```bash
racket test/test-settings.rkt && \
racket test/test-theme.rkt && \
racket test/test-project.rkt && \
racket test/test-keybindings.rkt && \
racket test/test-extension.rkt && \
racket test/test-bridge.rkt && \
racket test/test-phase2.rkt && \
racket test/test-phase4.rkt && \
racket test/test-lang-intel.rkt && \
racket test/test-stepper.rkt && \
racket test/test-macro-expander.rkt && \
racket test/test-pattern-extractor.rkt && \
racket test/test-rhombus.rkt && \
racket test/test-ui.rkt && \
racket test/test-component.rkt && \
racket test/test-extend-lang.rkt && \
racket test/test-phase5b-integration.rkt
```

Expected: All tests pass.

**Step 2: Verify Rust builds**

```bash
cd /Users/antony/Development/Linkuistics/MrRacket && cargo build -p heavy-mental
```

Expected: Build succeeds.

**Step 3: Test the app runs**

```bash
cargo tauri dev
```

Verify:
- App launches with light theme
- Cmd+, opens settings panel (or dispatches settings:open)
- Dark/light theme switching works
- Cmd+Shift+F opens search panel
- Keybindings are displayed

**Step 4: Final commit**

```bash
git commit -m "feat: Phase 6 complete — polish and distribution"
```

---

## Parallel Track Assignment

**Track 1 (Tasks 1-4):** Settings + Theming — subagent A
**Track 2 (Tasks 5-7):** Multi-file Projects — subagent B
**Track 3 (Tasks 8-10):** Keyboard Shortcuts — subagent C
**Integration (Task 11):** Settings UI — after tracks 1-3 complete
**Packaging (Task 12):** Bundle config — after integration
**Verification (Task 13):** Final testing — last
