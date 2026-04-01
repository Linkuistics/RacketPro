# TODO -- RacketPro Next Steps

Each item below is a self-contained Claude Code prompt. Copy the full text of a task into a new Claude Code session to execute it.

---

## Transition to APIAnyware-MacOS

### Replace Tauri bridge with APIAnyware-MacOS native bindings

```
The RacketPro IDE at /Users/antony/Development/RacketPro currently uses a Tauri/Rust
bridge (src-tauri/) to spawn Racket, route JSON-RPC messages, manage PTY processes,
handle file I/O, and render native menus. The long-term architecture replaces this
with APIAnyware-MacOS bindings so Racket directly accesses macOS APIs (AppKit, WebKit,
Foundation) without an intermediary.

Investigate APIAnyware-MacOS at https://github.com/linkuistics/APIAnyware-MacOS and
create a migration plan. Identify which Rust bridge responsibilities can be replaced
by direct Racket-to-macOS calls via APIAnyware. Start with the simplest subsystem
(e.g., native menus or file dialogs) as a proof-of-concept.
```

---

## Language Intelligence Improvements

### Add debounced re-analysis on the Racket side

```
In /Users/antony/Development/RacketPro, the language intelligence system
(racket/heavymental-core/lang-intel.rkt) re-runs check-syntax on every
document:changed event. The frontend debounces edits, but the Racket side has no
debouncing -- rapid saves or automated edits can queue multiple expensive analyses.

Add a debounce mechanism in lang-intel.rkt: when handle-document-changed is called,
cancel any pending analysis for the same URI and schedule a new one after 300ms of
inactivity. Use a thread + sleep approach similar to the extension reload debounce
in extension.rkt.
```

### Add Typed Racket intelligence support

```
In /Users/antony/Development/RacketPro, the language intelligence pipeline
(racket/heavymental-core/lang-intel.rkt) treats all #lang variants that start with
"typed/" as plain "racket". Enhance the pipeline to properly handle #lang typed/racket
files -- the check-syntax integration already works, but type-hover information and
type-error diagnostics could be richer. Investigate whether typed/racket's check-syntax
annotations include type information in the hover text, and if not, whether we can
extract it from the expansion.
```

---

## Stepper and Macro Expander

### Add Rhombus stepper support

```
In /Users/antony/Development/RacketPro, the algebraic stepper
(racket/heavymental-core/stepper.rkt) currently only supports #lang racket files.
When a Rhombus file is selected, it shows an error message. Investigate whether
Racket's stepper/private/model can be used with Rhombus programs, or whether a
different approach is needed. If Rhombus stepping is feasible, implement it.
If not, document the technical limitation clearly.
```

### Improve macro expander pattern extraction

```
In /Users/antony/Development/RacketPro, the pattern extractor
(racket/heavymental-core/pattern-extractor.rkt) currently handles
define-syntax-rule and define-syntax-parse-rule. Extend it to also handle
syntax-case and syntax-parse based macros (the common define-syntax + syntax-case
pattern). These are widely used in real Racket code and currently produce no
pattern information in the macro expansion panel.
```

---

## UI and UX

### Add file rename and delete support in the file tree

```
In /Users/antony/Development/RacketPro, the file tree component
(frontend/core/primitives/filetree.js) supports opening files but not renaming
or deleting them. Add right-click context menu support to the file tree with
Rename and Delete options. The rename operation should use a native dialog for
the new name. The delete operation should show a confirmation dialog. Both
operations need corresponding Rust bridge handlers in src-tauri/src/bridge.rs
and fs.rs, with messages routed through the standard JSON-RPC protocol.
```

### Add split editor (side-by-side editing)

```
In /Users/antony/Development/RacketPro, the layout currently supports a single
editor pane. Add support for split editor views -- the user should be able to
open a second editor pane showing a different file side-by-side. This requires:
1. A new "split-editor" menu action and keybinding
2. Layout modification in main.rkt to support multiple editor nodes
3. Tab management updates in editor.rkt to track which editor pane is active
4. Frontend support for multiple hm-editor instances with independent Monaco editors
```

### Add breadcrumb path navigation

```
In /Users/antony/Development/RacketPro, the layout includes a breadcrumb component
(type "breadcrumb" in main.rkt) that shows the current file path relative to the
project root. Verify it renders correctly and add clickable path segments that
navigate to parent directories in the file tree. The breadcrumb should also show
action buttons for Run and Step Through for quick access.
```

---

## Testing

### Expand E2E test coverage

```
In /Users/antony/Development/RacketPro, there are E2E tests in test/e2e-app/
that test boot, file tree, editor, tabs, REPL, stepper, breadcrumb, layout,
statusbar, editor content, diagnostics, semantic colors, dirty indicators,
terminal output, intel roundtrip, and multi-file workflow. Review the existing
test coverage and add tests for:
1. Macro expander panel (expand macros on a file with define-syntax-rule)
2. Extension loading and unloading
3. Project search (Cmd+Shift+F workflow)
4. Settings panel (open, change a setting, verify persistence)
5. Theme switching (Light to Dark and back)
6. Keybinding customization
```

### Add Racket unit tests for settings and theme modules

```
In /Users/antony/Development/RacketPro, the test/ directory has test files for
most Racket modules but test-settings.rkt and test-theme.rkt may need expansion.
Review test/test-settings.rkt and test/test-theme.rkt. Ensure they cover:
- settings: deep-merge behavior, apply-loaded-settings!, settings-ref with defaults
- theme: register-theme!, get-theme, list-themes, custom theme registration
Add any missing coverage.
```

---

## Build and Distribution

### Set up CI pipeline

```
In /Users/antony/Development/RacketPro, there is no CI configuration. Create a
GitHub Actions workflow (.github/workflows/ci.yml) that:
1. Installs Rust, Racket, and drracket-tool-lib
2. Runs all Racket unit tests (racket test/test-*.rkt)
3. Builds the Tauri app (cargo tauri build)
4. Caches Rust and Racket dependencies for faster runs
Target macOS runners since the app requires WKWebView.
```

### Create DMG installer with branding

```
In /Users/antony/Development/RacketPro, the Tauri build produces a DMG but
uses default Tauri icons. Create branded app icons for RacketPro and update
src-tauri/icons/. The DMG should show the RacketPro icon and a drag-to-Applications
layout. Update src-tauri/tauri.conf.json with correct product name, bundle
identifier, and descriptions that reference "RacketPro" for the public-facing name.
```

---

## Extension Ecosystem

### Create extension development guide and template

```
In /Users/antony/Development/RacketPro, the extensions/ directory contains example
extensions (counter, timer, file-watcher, calc-lang, etc.) that demonstrate the
extension API. Create a comprehensive extension development guide as a template
extension with detailed comments explaining every feature of define-extension:
cells, panels, events, menus, on-activate/on-deactivate hooks, the ui macro for
building layouts, filesystem watching, and live reload behavior. Include examples
of each feature. Put the template at extensions/template-extension.rkt.
```

### Add extension marketplace/registry concept

```
In /Users/antony/Development/RacketPro, extensions are currently loaded from local
.rkt files via a file dialog. Design and implement an extension registry that:
1. Scans a known directory (~/.config/racketpro/extensions/) on startup
2. Auto-loads extensions found there
3. Supports an extensions.rkt manifest listing extensions to load
This would make extension management more practical than manual file-by-file loading.
```
