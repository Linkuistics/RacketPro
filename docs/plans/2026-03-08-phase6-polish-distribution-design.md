# Phase 6: Polish + Distribution — Design

**Date**: 2026-03-08
**Status**: Approved

## Scope

Phase 6 takes HeavyMental from feature-complete to shippable. Five areas:

1. **Theming** — Racket-driven theme system with dark/light mode
2. **Settings persistence** — Two-tier: global JSON + per-project Racket config
3. **Multi-file projects** — Directory-is-project with `info.rkt` detection, find-in-project
4. **Keyboard shortcuts** — Keybinding registry, non-menu shortcuts, vim mode, visual editor
5. **Packaging** — DMG installer, app icon, Racket-not-found detection

Dropped from scope: tray icon (not needed at this stage).

## Implementation Structure: Parallel Tracks

Three independent tracks executed concurrently via subagents, then integration:

- **Track 1:** Settings persistence + theming (tightly coupled)
- **Track 2:** Multi-file projects (independent)
- **Track 3:** Keybinding system (independent)
- **Integration:** Settings UI panel (depends on all three tracks)
- **Final:** Packaging

## Track 1: Theming + Settings Persistence

### Theming

Racket owns theme definitions as hasheqs:

```racket
(define light-theme
  (hasheq 'name "Light"
          'bg-primary "#FFFFFF"
          'bg-secondary "#F3F3F3"
          'fg-primary "#333333"
          ...))

(define dark-theme
  (hasheq 'name "Dark"
          'bg-primary "#1E1E1E"
          'bg-secondary "#252526"
          'fg-primary "#D4D4D4"
          ...))
```

**Message flow:**
- Racket sends `theme:apply` with full variable map
- Frontend iterates and calls `document.documentElement.style.setProperty()` for each
- `_current-theme` cell tracks the active theme name
- On startup, Racket reads saved theme from settings and sends `theme:apply`

**Monaco integration:**
- Monaco has its own theme system (`vs` / `vs-dark`)
- `theme:apply` message includes a `monaco-theme` field
- Frontend calls `monaco.editor.setTheme()` alongside CSS variable updates

**Extension-provided themes:**
- Extensions register themes via `define-extension` with `#:themes` keyword
- Theme registry: `register-theme!`, `list-themes`, `get-theme`
- Built-in themes (light, dark) always available; extensions add to the list

**Files:**
- New: `racket/heavymental-core/theme.rkt`
- New: `frontend/core/theme.js`
- Modified: `main.rkt`, `bridge.js`

### Settings Persistence

**Global settings** — `~/Library/Application Support/com.linkuistics.heavymental/settings.json`

```json
{
  "theme": "Dark",
  "editor": { "fontFamily": "SF Mono", "fontSize": 13, "fontWeight": 300, "vimMode": false },
  "keybindings": { "run": "Cmd+R", "settings": "Cmd+," },
  "window": { "width": 1200, "height": 800 },
  "recentFiles": ["/path/to/file.rkt"]
}
```

- Rust reads on startup → sends `settings:loaded` to Racket
- Racket sends `settings:save` on change → Rust writes JSON
- Rust manages the OS app data directory path

**Per-project settings** — `.heavymental/settings.rkt` (optional)

```racket
#lang racket/base
(provide project-settings)
(define project-settings
  (hasheq 'run-command "racket main.rkt"
          'exclude-dirs '(".git" "compiled" "node_modules")))
```

- Racket reads via `dynamic-require` when `project-root` changes
- Overrides global settings where applicable

**Merge order:** defaults → global JSON → per-project Racket

**Files:**
- New: `racket/heavymental-core/settings.rkt`
- New: `src-tauri/src/settings.rs`
- Modified: `bridge.rs`, `main.rkt`

## Track 2: Multi-File Projects

### Project Detection

- On file open, walk up directory tree looking for `info.rkt`
- If found: project root = that directory, read collection metadata
- If not found: fall back to file's parent directory (current behavior)
- `info.rkt` data extracted: collection name (shown in title/status bar), deps, test paths

### Find-in-Project

- `project:search` message: Racket → Rust (query, regex flag, case-sensitive flag, file globs)
- Rust performs search using `ignore` crate (respects `.gitignore`) + `grep` crate
- Results: `project:search:results` with file path, line, match text, context lines
- Default excludes: `.git`, `compiled`, `node_modules`, `.heavymental`
- Per-project overrides via `.heavymental/settings.rkt`

### Search Panel

- New bottom panel tab: SEARCH
- `hm-search-panel` component: search input, options (regex, case), grouped results by file
- Clicking a result triggers `editor:goto-file`
- Cmd+Shift+F opens search panel and focuses input

**Files:**
- New: `src-tauri/src/search.rs`
- New: `racket/heavymental-core/project.rkt`
- New: `frontend/core/primitives/search-panel.js`
- Modified: `bridge.rs`, `main.rkt`

## Track 3: Keyboard Shortcuts

### Keybinding Registry

Racket maintains a keybinding table separate from menus:

```racket
(define default-keybindings
  (hasheq "Cmd+S" "editor:save-request"
          "Cmd+R" "run"
          "Cmd+," "settings:open"
          "Cmd+Shift+F" "project:search-focus"
          "Cmd+P" "quick-open"
          "Cmd+`" "terminal:focus"
          ...))
```

- Defaults + user overrides (from settings) merged on startup
- When keybinding changes: Racket rebuilds menus with updated accelerators AND sends `keybindings:set` to frontend

### Frontend Keydown Handler

- `keybindings.js` registers global `keydown` listener
- Translates key combos to shortcut strings (e.g., `Cmd+Shift+F`)
- Checks against active keymap (received from Racket via `keybindings:set`)
- If matched: dispatches `keybinding:action` to Racket, calls `preventDefault()`
- Monaco keybindings untouched — only captures what Monaco doesn't handle

### Vim Mode

- `editor.vimMode` setting (boolean, default false)
- Vendor `monaco-vim` ESM into `frontend/vendor/`
- Frontend loads and activates on editor instance when enabled
- Vim status line (mode, command) shown in status bar
- `editor:set-vim-mode` message toggles it live
- No conflict with global keybindings — vim bindings are editor-internal

**Files:**
- New: `racket/heavymental-core/keybindings.rkt`
- New: `frontend/core/keybindings.js`
- New: `frontend/vendor/monaco-vim/` (vendored ESM)
- Modified: `main.rkt`, `primitives/editor.js`

## Integration: Settings UI Panel

### Access

- Cmd+, or File → Settings
- Opens as a special tab in the editor area (gear icon, "Settings" title)

### Component Structure

```
hm-settings-panel
  +-- hm-settings-nav (sidebar with section links)
  +-- hm-settings-content
       +-- section: Appearance (theme dropdown, font family/size/weight)
       +-- section: Editor (vim mode toggle, tab size, word wrap, minimap, line numbers)
       +-- section: Keybindings (hm-keybinding-editor)
       +-- section: Project (run command, excluded dirs — only if per-project config exists)
```

### Keybinding Editor

- Filterable table: Action Name | Category | Shortcut | Reset
- Click shortcut cell → "Press key combination..." overlay → capture keydown → validate
- Conflicts shown inline with link to conflicting action
- "Reset to Default" per binding
- Changes dispatch `keybinding:set` to Racket and persist via settings

**Files:**
- New: `frontend/core/primitives/settings-panel.js`
- New: `frontend/core/primitives/keybinding-editor.js`
- Modified: `main.rkt`, `renderer.js`

## Packaging

### DMG Installer

Tauri bundle configuration in `tauri.conf.json`:

```json
{
  "bundle": {
    "active": true,
    "targets": ["dmg"],
    "icon": ["icons/icon.icns", "icons/icon.png"],
    "category": "DeveloperTool",
    "copyright": "© 2026 Linkuistics",
    "shortDescription": "A Racket-driven IDE",
    "macOS": {
      "minimumSystemVersion": "13.0"
    }
  }
}
```

### App Icon

- 1024x1024 PNG source → `cargo tauri icon` generates all sizes
- Stored in `src-tauri/icons/`

### Racket-not-found Detection

- Before spawning Racket process, check if `racket` exists on PATH
- If missing: show native dialog with install instructions (link to racket-lang.org)
- Check happens in Rust bridge startup

**Files:**
- Modified: `src-tauri/tauri.conf.json`
- New: `src-tauri/icons/`
- Modified: `bridge.rs`

## What Already Exists (Not Reimplemented)

- Native menus: already Racket-driven (`menu:set`), extensions merge
- Menu accelerator shortcuts: already work
- `cargo tauri build`: already produces `.app` bundle
- Extension system: complete (load/unload/reload, manager, live reload)
- CSS custom properties: 60+ variables in `reset.css`, consistently used by all components
