# TODO -- RacketPro Next Steps

Each item below is a self-contained Claude Code prompt. Copy the full text of a task into a new Claude Code session to execute it.

---

## Rename internal HeavyMental references to RacketPro

The repository is called RacketPro but the internal product name is "HeavyMental" everywhere. This creates confusion for users and contributors.

```
Audit every occurrence of "HeavyMental" and "heavymental" across the RacketPro
codebase at /Users/antony/Development/RacketPro and rename to "RacketPro" and
"racketpro" respectively. Key locations:

- src-tauri/Cargo.toml: package name "heavy-mental", lib name "heavy_mental_lib"
- src-tauri/tauri.conf.json: productName "HeavyMental", identifier
  "com.linkuistics.heavymental", bundle descriptions
- src-tauri/src/main.rs: heavy_mental_lib::run()
- src-tauri/src/bridge.rs: menu labels "About HeavyMental", "Hide HeavyMental",
  "Quit HeavyMental"
- src-tauri/src/settings.rs: path "com.linkuistics.heavymental"
- src-tauri/src/debug.rs: path "/tmp/heavymental-debug/"
- racket/heavymental-core/: directory name
- racket/heavymental-core/info.rkt: collection "heavymental", pkg-desc
- racket/heavymental-core/main.rkt: cell title default "HeavyMental", title
  format strings "HeavyMental -- filename"
- racket/heavymental-core/editor.rkt: title format strings with "HeavyMental"
- frontend/index.html: <title>HeavyMental</title>
- CLAUDE.md: all references
- extensions/ files: require paths heavymental/extension, heavymental/cell,
  heavymental/ui
- test/ files: relative require paths to ../racket/heavymental-core/

Rename the racket/heavymental-core/ directory to racket/racketpro-core/ and
update all paths. Update the Racket info.rkt collection name. Update every
require that references heavymental. Run all tests after renaming. Build with
cargo tauri dev to verify the app launches correctly.
```

---

## Vendor monaco-vim for functional vim mode

The vim mode toggle exists in the settings panel and `frontend/core/primitives/editor.js` has full scaffolding, but `frontend/vendor/monaco-vim/index.js` is a placeholder stub that logs a warning.

```
Vendor the monaco-vim library into /Users/antony/Development/RacketPro/frontend/vendor/monaco-vim/.
The current index.js is a placeholder stub. Download or build the ESM bundle from
https://github.com/brijeshb42/monaco-vim and replace the stub. The editor
component (frontend/core/primitives/editor.js) already imports it dynamically
via `import('../../vendor/monaco-vim/index.js')` and calls `initVimMode(editor,
statusEl)`. Verify it works with `cargo tauri dev` by toggling vim mode in the
settings panel. Once working, update the README.md vim mode description to
remove the "not yet vendored" note.
```

---

## Transition from Tauri to APIAnyware-MacOS

The architecture goal is to replace the Tauri/Rust bridge with direct APIAnyware-MacOS bindings so Racket drives native macOS APIs without an intermediary.

```
Begin the transition from Tauri to APIAnyware-MacOS bindings in
/Users/antony/Development/RacketPro. The current architecture has three layers
(Frontend <-> Rust/Tauri <-> Racket) and the goal is two layers (Frontend <->
Racket via APIAnyware-MacOS). Start by:

1. Investigate APIAnyware-MacOS at https://github.com/linkuistics/APIAnyware-MacOS
2. Identify which Rust bridge responsibilities can be replaced:
   - Spawning WebKit windows (WKWebView)
   - Evaluating JavaScript in the WebView
   - Native menu construction (NSMenu/NSMenuItem)
   - File dialogs (NSOpenPanel/NSSavePanel)
   - PTY management (posix_openpt)
   - Filesystem operations
   - Settings persistence
3. Create a proof-of-concept that opens a WebKit window from Racket using
   APIAnyware-MacOS and loads the existing frontend/index.html
4. Implement the JSON message bridge directly from Racket (replacing bridge.rs)

The frontend should remain unchanged -- it already communicates via a bridge
abstraction (frontend/core/bridge.js) that can be re-targeted.
```

---

## Add Racket-side analysis debouncing

The language intelligence system re-runs `check-syntax` on every `document:changed` event. The frontend debounces edits, but the Racket side has no debouncing.

```
In /Users/antony/Development/RacketPro, add a debounce mechanism to
racket/heavymental-core/lang-intel.rkt. When handle-document-changed is called,
cancel any pending analysis for the same URI and schedule a new one after 300ms
of inactivity. Use a thread + sleep approach similar to the extension reload
debounce in extension.rkt (see handle-extension-file-change). Store pending
analysis threads in a hash keyed by URI. Cancel (kill-thread) and replace on
each new change event.
```

---

## Add Typed Racket intelligence support

Check-syntax works for `#lang typed/racket` but type information could be richer.

```
In /Users/antony/Development/RacketPro, enhance the language intelligence
pipeline (racket/heavymental-core/lang-intel.rkt) for #lang typed/racket.
Currently all typed/* langs map to "racket" in editor.rkt. Investigate:
1. Whether check-syntax annotations from typed/racket include type information
   in the hover text (syncheck:add-mouse-over-status)
2. Whether typed/racket type errors produce useful source locations via
   exn:fail:syntax?
3. If type hovers aren't provided by check-syntax, explore using
   typed-racket/optimizer/tool/tool to extract type information
Add test cases in test/test-lang-intel.rkt with a typed/racket source string.
```

---

## Add Rhombus stepper support

The stepper currently rejects Rhombus files with an error message.

```
In /Users/antony/Development/RacketPro, the algebraic stepper
(racket/heavymental-core/stepper.rkt) only supports #lang racket. When a
Rhombus file is selected, main.rkt shows "The stepper is not yet supported for
Rhombus files." Investigate whether Racket's stepper/private/model can process
Rhombus programs (Rhombus compiles through the Racket expander). If feasible,
implement it. If not, document the technical limitation. The stepper uses
read-syntax to read forms after skipping the #lang line, which won't work for
Rhombus's shrubbery syntax -- a different reader would be needed.
```

---

## Improve macro expander pattern extraction

The pattern extractor only handles `define-syntax-rule` and `define-syntax-parse-rule`.

```
In /Users/antony/Development/RacketPro, extend the pattern extractor
(racket/heavymental-core/pattern-extractor.rkt) to also handle:
1. define-syntax + syntax-case macros (the common pattern)
2. define-syntax + syntax-parse macros
3. define-simple-macro
These are widely used in real Racket code and currently produce no pattern
information in the macro expansion panel. The extractor reads S-expressions
from the source file, so new matchers should follow the existing
match-define-syntax-rule pattern using racket/match. Add test cases in
test/test-pattern-extractor.rkt.
```

---

## Add file rename and delete in the file tree

The file tree only supports opening files.

```
In /Users/antony/Development/RacketPro, add right-click context menu support
to the file tree (frontend/core/primitives/filetree.js) with Rename, Delete,
and New File options. Implementation:
1. Add a context menu Web Component or use native context menus
2. Rename: dispatch an event to Racket, which sends a file:rename message
   to Rust, which performs the fs::rename
3. Delete: show a confirmation dialog, then dispatch file:delete
4. New File: prompt for name, then dispatch file:create
5. Add corresponding handlers in src-tauri/src/bridge.rs for file:rename,
   file:delete, and file:create message types
6. After mutations, the file tree should refresh
```

---

## Add split editor (side-by-side editing)

The layout supports only a single editor pane.

```
In /Users/antony/Development/RacketPro, add support for split editor views.
The user should be able to open a second editor pane showing a different file
side-by-side. This requires:
1. A new "split-editor" menu action and keybinding in main.rkt
2. Layout modification in main.rkt to dynamically insert a second editor node
   inside an hm-split
3. Editor state tracking: editor.rkt must track which editor pane is active
   and route file:read:result and editor:goto to the correct pane
4. Tab management: tabs should indicate which pane they belong to
5. Frontend: ensure multiple hm-editor instances with independent Monaco
   editors can coexist (they currently can, but test thoroughly)
```

---

## Add Scribble documentation support

Racket's documentation is written in Scribble. The editor detects `.scrbl` as "racket" but has no Scribble-specific support.

```
Add Scribble (.scrbl) support to /Users/antony/Development/RacketPro:
1. Create a Monaco language definition for Scribble in
   frontend/core/scribble-language.js (handling @-expressions, @racketblock,
   @defproc, @title, etc.)
2. Register it in frontend/core/primitives/editor.js
3. Update racket/heavymental-core/editor.rkt detect-language to return
   "scribble" for .scrbl files
4. The check-syntax pipeline should still work since Scribble files are
   Racket modules -- verify this with a test .scrbl file
```

---

## Add PLT Redex integration

PLT Redex is Racket's tool for modeling reduction semantics.

```
Add PLT Redex support to /Users/antony/Development/RacketPro. Implement:
1. A "Redex" tab in the bottom tabs (add to main.rkt layout)
2. A redex.rkt module in racket/heavymental-core/ that uses
   redex/reduction-semantics to trace reductions
3. A frontend hm-redex-panel component that displays reduction steps
4. The Racket side should send redex:step messages with before/after terms
   and highlighted positions, similar to stepper.rkt
5. Consider using Redex's typesetting capabilities to generate rendered output
```

---

## Add code formatting

No code formatting support exists yet.

```
Add Racket code formatting to /Users/antony/Development/RacketPro:
1. Integrate with raco fmt (if available) or implement basic indentation rules
2. Add a "Format Document" menu action with Cmd+Shift+I shortcut
3. Wire it through the menu and keybinding system in main.rkt
4. The formatting should work by sending the current editor content to Racket,
   which runs the formatter and sends back the formatted content
5. Consider format-on-save as a settings option in settings.rkt
```

---

## Add test runner integration

The project has many test files but no in-IDE test runner.

```
Add a test runner panel to /Users/antony/Development/RacketPro:
1. Add a "Tests" tab to the bottom tabs in main.rkt's layout
2. Create test-runner.rkt in racket/heavymental-core/ that discovers rackunit
   test files in the project and runs them
3. Parse rackunit output to extract pass/fail/error results with source
   locations
4. Create an hm-test-panel Web Component for displaying results with
   clickable links to failure locations (using editor:goto-file)
5. Add a "Run Tests" menu item (Cmd+T or similar) and keybinding
6. Run tests in a separate PTY so the REPL remains available
```

---

## Expand E2E test coverage

Existing E2E tests cover core features but miss several subsystems.

```
In /Users/antony/Development/RacketPro, expand E2E test coverage in
test/e2e-app/tests/. Add tests for:
1. Macro expander panel (expand macros on a file with define-syntax-rule,
   verify steps appear)
2. Extension loading and unloading (load counter.rkt, verify panel appears,
   unload, verify panel removed)
3. Project search (Cmd+Shift+F, type query, verify results)
4. Settings panel (open, change font size, verify it applies)
5. Theme switching (Light to Dark, verify CSS variables change)
6. Keybinding customization (rebind a key, verify new binding works)
Follow the pattern in existing tests (helpers.mjs for utilities).
```

---

## Set up CI pipeline

No CI configuration exists.

```
Create a GitHub Actions CI workflow for /Users/antony/Development/RacketPro
at .github/workflows/ci.yml that:
1. Runs on macOS (macos-latest or macos-14 for Apple Silicon)
2. Installs Rust via rustup (version from .tool-versions: 1.93.1)
3. Installs Racket and runs: raco pkg install --auto drracket-tool-lib
4. Runs all Racket unit tests: for f in test/test-*.rkt; do racket "$f"; done
5. Builds the Tauri app: cargo tauri build
6. Caches Rust target/ and Racket package directories
7. Triggers on push to main and pull requests
```

---

## Create branded app icon and DMG

The app uses default Tauri icons.

```
In /Users/antony/Development/RacketPro, create a branded application icon
for RacketPro. The icon should reflect Racket/language-building themes while
fitting the Linkuistics brand. Generate all required icon sizes in
src-tauri/icons/ (32x32, 64x64, 128x128, 128x128@2x, icon.icns, icon.ico,
icon.png). Update src-tauri/tauri.conf.json bundle section. Create a DMG
background image. Test with cargo tauri build that the .app and .dmg use
the new icons correctly.
```

---

## Create extension development guide

The extension system is powerful but documentation is minimal.

```
In /Users/antony/Development/RacketPro, create a template extension at
extensions/template-extension.rkt with comprehensive comments explaining every
feature of the extension API:
- The define-extension macro with all keyword options (#:name, #:cells,
  #:panels, #:events, #:menus, #:on-activate, #:on-deactivate)
- The #lang heavymental/extend surface syntax alternative
- The (ui ...) macro DSL for building layout trees
- Custom components via define-component
- Cell namespacing (extension cells are auto-prefixed with ext-id:)
- Event dispatch (extension events are auto-prefixed)
- Menu integration (adding items to existing menus)
- Filesystem watching via watch-directory!
- Live reload behavior (edit, save, auto-reload with debounce)
Each feature should have a working example in the template.
```

---

## Add extension auto-discovery

Extensions are currently loaded manually via file dialog.

```
In /Users/antony/Development/RacketPro, add extension auto-discovery:
1. On startup, scan ~/.config/racketpro/extensions/ for .rkt files
2. Auto-load any extensions found there
3. Add support for an extensions.rkt manifest file that lists extension paths
4. Add an "Install Extension" option that copies an extension file to the
   auto-load directory
5. Implementation: add auto-load logic to main.rkt's startup sequence,
   after register-all-cells! but before start-message-loop
```
