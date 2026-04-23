# RacketPro

Racket-driven IDE built on Tauri. Racket is the brain: it declares UI, manages state, handles events, controls menus. Rust/Tauri is a thin bridge. Frontend is Lit Web Components + signals.

## Tasks

### Rename internal HeavyMental references to RacketPro

**Category:** `rename`
**Status:** not_started
**Dependencies:** none

**Description:**

**Dependency context:** Should be done first — many other tasks reference heavymental paths.

Audit every occurrence of "HeavyMental" and "heavymental" across the codebase and rename to "RacketPro" and "racketpro". Key locations: Cargo.toml package/lib names, tauri.conf.json productName/identifier/bundle, main.rs lib reference, bridge.rs menu labels, settings.rs path, debug.rs path, racket/heavymental-core/ directory (rename to racket/racketpro-core/), info.rkt collection name, main.rkt/editor.rkt title strings, index.html title, extensions/ require paths, test/ relative require paths, CLAUDE.md references. Run all tests and verify the app launches after renaming.

**Results:** _pending_

---

### Vendor monaco-vim for functional vim mode

**Category:** `editor`
**Status:** not_started
**Dependencies:** none

**Description:**

The vim mode toggle exists in settings and editor.js has full scaffolding, but frontend/vendor/monaco-vim/index.js is a placeholder stub. Download or build the ESM bundle from https://github.com/brijeshb42/monaco-vim and replace the stub. The editor component already imports it dynamically and calls initVimMode(editor, statusEl). Verify with cargo tauri dev by toggling vim mode in settings.

**Results:** _pending_

---

### Add Racket-side analysis debouncing

**Category:** `editor`
**Status:** not_started
**Dependencies:** none

**Description:**

The language intelligence system re-runs check-syntax on every document:changed event with no Racket-side debouncing. Add a debounce mechanism to lang-intel.rkt: when handle-document-changed is called, cancel any pending analysis for the same URI and schedule a new one after 300ms of inactivity. Use a thread + sleep approach similar to the extension reload debounce in extension.rkt. Store pending analysis threads in a hash keyed by URI.

**Results:** _pending_

---

### Add file rename and delete in the file tree

**Category:** `editor`
**Status:** not_started
**Dependencies:** none

**Description:**

The file tree only supports opening files. Add right-click context menu support to filetree.js with Rename, Delete, and New File options. Wire each through the message bridge: file:rename, file:delete, file:create handlers in bridge.rs performing fs operations. After mutations, the file tree should refresh.

**Results:** _pending_

---

### Add split editor (side-by-side editing)

**Category:** `editor`
**Status:** not_started
**Dependencies:** none

**Description:**

Add support for split editor views — a second editor pane showing a different file side-by-side. Requires: a split-editor menu action and keybinding in main.rkt, layout modification to dynamically insert a second editor node inside an hm-split, editor state tracking in editor.rkt for active pane routing, tab management indicating which pane tabs belong to, and verification that multiple hm-editor instances with independent Monaco editors coexist.

**Results:** _pending_

---

### Add code formatting

**Category:** `editor`
**Status:** not_started
**Dependencies:** none

**Description:**

Add Racket code formatting support. Integrate with raco fmt (if available) or implement basic indentation rules. Add a "Format Document" menu action with Cmd+Shift+I shortcut wired through the menu/keybinding system in main.rkt. Send current editor content to Racket for formatting, return formatted content. Consider format-on-save as a settings option in settings.rkt.

**Results:** _pending_

---

### Improve macro expander pattern extraction

**Category:** `intelligence`
**Status:** not_started
**Dependencies:** none

**Description:**

The pattern extractor (pattern-extractor.rkt) only handles define-syntax-rule and define-syntax-parse-rule. Extend to also handle: define-syntax + syntax-case macros, define-syntax + syntax-parse macros, and define-simple-macro. These are widely used in real Racket code. New matchers should follow the existing match-define-syntax-rule pattern using racket/match. Add test cases in test/test-pattern-extractor.rkt.

**Results:** _pending_

---

### Add Typed Racket intelligence support

**Category:** `intelligence`
**Status:** not_started
**Dependencies:** none

**Description:**

Enhance the language intelligence pipeline (lang-intel.rkt) for #lang typed/racket. Investigate: whether check-syntax annotations include type information in hover text (syncheck:add-mouse-over-status), whether typed/racket type errors produce useful source locations via exn:fail:syntax?, and if type hovers aren't provided by check-syntax, explore typed-racket/optimizer/tool/tool for type extraction. Add test cases in test/test-lang-intel.rkt with typed/racket source.

**Results:** _pending_

---

### Add Rhombus stepper support

**Category:** `intelligence`
**Status:** not_started
**Dependencies:** none

**Description:**

The algebraic stepper (stepper.rkt) only supports #lang racket. Rhombus files get an error message. Investigate whether stepper/private/model can process Rhombus programs (Rhombus compiles through the Racket expander). The stepper uses read-syntax to read forms after skipping the #lang line, which won't work for Rhombus's shrubbery syntax — a different reader would be needed. If not feasible, document the technical limitation.

**Results:** _pending_

---

### Add Scribble documentation support

**Category:** `intelligence`
**Status:** not_started
**Dependencies:** none

**Description:**

Add Scribble (.scrbl) support: create a Monaco language definition for Scribble in frontend/core/scribble-language.js (handling @-expressions, @racketblock, @defproc, @title, etc.), register it in editor.js, update editor.rkt detect-language to return "scribble" for .scrbl files. The check-syntax pipeline should still work since Scribble files are Racket modules — verify with a test .scrbl file.

**Results:** _pending_

---

### Add PLT Redex integration

**Category:** `intelligence`
**Status:** not_started
**Dependencies:** none

**Description:**

Add PLT Redex support: a "Redex" tab in the bottom tabs (add to main.rkt layout), a redex.rkt module using redex/reduction-semantics to trace reductions, a frontend hm-redex-panel component displaying reduction steps, and Racket-side redex:step messages with before/after terms and highlighted positions (similar to stepper.rkt). Consider using Redex's typesetting capabilities for rendered output.

**Results:** _pending_

---

### Add test runner integration

**Category:** `testing`
**Status:** not_started
**Dependencies:** none

**Description:**

Add a test runner panel to the IDE: a "Tests" tab in the bottom tabs (main.rkt layout), a test-runner.rkt module that discovers rackunit test files and runs them, parsing output for pass/fail/error results with source locations, an hm-test-panel Web Component displaying results with clickable links to failure locations (editor:goto-file), a "Run Tests" menu item with keybinding, running tests in a separate PTY so the REPL remains available.

**Results:** _pending_

---

### Expand E2E test coverage

**Category:** `testing`
**Status:** not_started
**Dependencies:** none

**Description:**

Expand E2E test coverage in test/e2e-app/tests/. Add tests for: macro expander panel, extension loading/unloading, project search (Cmd+Shift+F), settings panel (font size), theme switching (Light to Dark CSS variables), and keybinding customization. Follow the pattern in existing tests (helpers.mjs for utilities).

**Results:** _pending_

---

### Transition from Tauri to APIAnyware-MacOS

**Category:** `platform`
**Status:** not_started
**Dependencies:** none

**Description:**

**Dependency context:** Large scope — consider splitting when starting.

Replace the Tauri/Rust bridge with direct APIAnyware-MacOS bindings so Racket drives native macOS APIs without an intermediary. Current architecture: Frontend <-> Rust/Tauri <-> Racket. Target: Frontend <-> Racket via APIAnyware-MacOS. Start by investigating APIAnyware-MacOS, identifying which Rust bridge responsibilities can be replaced (WebKit windows, JS eval, native menus, file dialogs, PTY management, filesystem ops, settings persistence), creating a PoC that opens a WebKit window from Racket loading frontend/index.html, and implementing the JSON message bridge directly from Racket. The frontend should remain unchanged — it communicates via a bridge abstraction (bridge.js) that can be re-targeted.

**Results:** _pending_

---

### Set up CI pipeline

**Category:** `platform`
**Status:** not_started
**Dependencies:** Rename internal HeavyMental references to RacketPro

**Description:**

**Dependency context:** CI should use final names.

Create a GitHub Actions CI workflow (.github/workflows/ci.yml) on macOS (macos-latest or macos-14 for Apple Silicon). Install Rust via rustup (1.93.1), install Racket with drracket-tool-lib, run all Racket unit tests, build the Tauri app (cargo tauri build), cache Rust target/ and Racket packages. Trigger on push to main and PRs.

**Results:** _pending_

---

### Create branded app icon and DMG

**Category:** `platform`
**Status:** not_started
**Dependencies:** Rename internal HeavyMental references to RacketPro

**Description:**

Create a branded application icon reflecting Racket/language-building themes within the Linkuistics brand. Generate all required sizes in src-tauri/icons/ (32x32, 64x64, 128x128, 128x128@2x, icon.icns, icon.ico, icon.png). Update tauri.conf.json bundle section. Create a DMG background image. Test with cargo tauri build that .app and .dmg use new icons.

**Results:** _pending_

---

### Add extension auto-discovery

**Category:** `integration`
**Status:** not_started
**Dependencies:** none

**Description:**

Extensions are currently loaded manually via file dialog. Add auto-discovery: on startup, scan ~/.config/racketpro/extensions/ for .rkt files and auto-load them. Add support for an extensions.rkt manifest file listing extension paths. Add an "Install Extension" option that copies an extension file to the auto-load directory. Implementation: add auto-load logic to main.rkt's startup sequence, after register-all-cells! but before start-message-loop.

**Results:** _pending_

---

### Create extension development guide

**Category:** `integration`
**Status:** not_started
**Dependencies:** none

**Description:**

Create a template extension at extensions/template-extension.rkt with comprehensive comments explaining every extension API feature: define-extension macro with all keyword options, #lang heavymental/extend surface syntax, (ui ...) macro DSL for layout trees, custom components via define-component, cell namespacing, event dispatch, menu integration, filesystem watching via watch-directory!, and live reload behavior. Each feature should have a working example.

**Results:** _pending_

---
