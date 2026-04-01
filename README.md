# RacketPro

> A Racket IDE from Linkuistics — professional tools for programming language ecosystems.

---

RacketPro is a native macOS IDE for Racket, Rhombus, and language development. Racket is the brain -- it declares the UI layout, manages application state, handles events, and controls menus. A Rust/Tauri bridge spawns the Racket process, routes JSON-RPC messages over stdin/stdout, and provides OS-level services (PTY, filesystem, native dialogs, menus). The frontend is a thin rendering surface using Lit Web Components with Preact signals, Monaco as the code editor, and xterm.js for the terminal. No framework, no build step.

Racket is a language-building language. Where other IDEs focus on writing programs, RacketPro is a **language workbench** -- optimized for building, testing, and debugging new languages using macros and DSLs.

## Why a Dedicated Racket IDE?

DrRacket is excellent for learning, but professional language development demands more: macro expansion visualization, syntax object inspection, `#lang`-aware intelligence, and seamless Rhombus support alongside Racket. RacketPro provides purpose-built tooling for the kind of work Racket uniquely enables -- designing and implementing programming languages.

## Key Features

### Language Workbench

- **Macro expansion visualization** -- traces macro transformations using `macro-debugger`, showing before/after states for each rewrite step, derivation trees, and pattern extraction for `define-syntax-rule` and `define-syntax-parse-rule` macros
- **Algebraic stepper** -- interactive step-through execution using Racket's stepper engine (`stepper/private/model`), with forward/back navigation, before/after reduction display, and a running bindings panel
- **`#lang`-aware editing** -- automatic language detection from `#lang` lines and file extensions, with per-language REPL switching

### Racket Intelligence

- **Check-syntax integration** -- powered by `drracket/check-syntax` for binding arrows, hover information, semantic coloring, diagnostics, go-to-definition (within-file and cross-file), and completion
- **Binding arrow visualization** -- SVG Bezier curves showing identifier binding relationships across the source, displayed on hover (matching DrRacket's behavior)
- **Per-language diagnostics** -- error reporting with source location extraction from syntax and read errors, unused require warnings

### Rhombus Support

- Full editing support for Rhombus, Racket's new surface syntax
- Shared intelligence pipeline -- Rhombus files benefit from the same check-syntax infrastructure
- Automatic REPL language switching when running Rhombus files (`racket -I rhombus`)

### Extension System

- **Racket-native extensions** -- extensions are Racket modules using `define-extension` with declarative cells, UI panels, event handlers, menu items, and lifecycle hooks
- **Live reload** -- filesystem watching with debounced auto-reload on file save; errors preserve the previous working version
- **Namespaced isolation** -- extension cells, events, and layout references are automatically prefixed to prevent collisions
- **UI contributions** -- extensions can add panels to the bottom tab bar and menu items to existing menus

### Editor and Environment

- **Monaco code editor** -- syntax highlighting for Racket and Rhombus with custom language definitions, configurable font/tab/wrap/minimap settings, vim mode scaffold (toggle in settings, library not yet vendored)
- **Integrated terminal** -- xterm.js terminal connected to a Racket REPL via PTY, with automatic resize and language-aware restart
- **File tree** -- project directory browser with lazy-loaded directory listing
- **Multi-tab editing** -- tab bar with dirty indicators, save-before-close dialogs, and tab management
- **Project search** -- regex-aware project-wide search using the `ignore` crate (respects `.gitignore`), with results displayed in a dedicated panel
- **Settings panel** -- configurable editor, terminal, and UI settings persisted to `~/Library/Application Support/com.linkuistics.heavymental/settings.json`
- **Themes** -- built-in Light and Dark themes with comprehensive CSS custom properties covering backgrounds, foregrounds, borders, sidebar, tabs, panels, and status bar; theme API supports registration of custom themes
- **Customizable keybindings** -- default keymap with recording-based rebinding UI, stored in settings
- **Native macOS menus** -- Racket declares the menu structure, Rust renders it as native AppKit menus with keyboard shortcuts, including standard macOS application menu items (About, Services, Hide, Quit)
- **Unsaved changes protection** -- dirty file tracking with save/don't-save/cancel dialogs on tab close and window close

## Architecture

RacketPro uses a three-layer message-passing design:

```
Frontend (Lit Web Components + @preact/signals-core)
    ↕ Tauri IPC (invoke / events)
Rust Bridge (spawns Racket, routes JSON, manages PTY/FS/menus/dialogs/settings)
    ↕ stdin/stdout JSON-RPC
Racket Core (state, layout, events, language intelligence)
```

**Racket to Frontend:** Racket calls `send-message!` which writes JSON to stdout. Rust reads it, either intercepts it (menus, PTY, file I/O, dialogs, settings) or emits a Tauri event `racket:<type>`. The frontend's `bridge.js` dispatches to registered `onMessage()` handlers.

**Frontend to Racket:** Frontend calls `dispatch(name, payload)` which invokes `send_to_racket`. Rust writes JSON to Racket's stdin. Racket's `start-message-loop` dispatches to `handle-event`.

### Reactive Cells

Racket declares named cells (`cell:register`) and updates them (`cell:update`). The frontend mirrors them as `@preact/signals-core` signals. Layout properties can reference cells with `"cell:<name>"` syntax, enabling reactive UI updates driven entirely from Racket.

### Layout System

Racket sends a declarative layout tree via `layout:set`. The renderer diffs by stable node IDs and maps each `type` to an `hm-<type>` custom element. Layout primitives include: `hm-vbox`, `hm-hbox`, `hm-split`, `hm-toolbar`, `hm-statusbar`, `hm-tabs`, `hm-bottom-tabs`, `hm-tab-content`, `hm-filetree`, `hm-breadcrumb`, `hm-panel-header`, `hm-editor`, `hm-terminal`, `hm-error-panel`, `hm-stepper`, `hm-macro-panel`, `hm-extension-manager`, `hm-search-panel`, `hm-settings-panel`. A Racket `ui` macro provides a declarative DSL for building layout trees, with automatic handler registration for event callbacks.

## Project Structure

```
RacketPro/
├── src-tauri/
│   └── src/
│       ├── lib.rs             # Tauri setup, command handlers, PATH augmentation
│       ├── bridge.rs          # Racket process bridge: JSON-RPC routing, menus, dialogs, file I/O
│       ├── pty.rs             # PTY process management (portable-pty)
│       ├── fs.rs              # File read/write, directory listing
│       ├── search.rs          # Project-wide text search (ignore + regex)
│       ├── settings.rs        # Settings persistence (~/Library/Application Support/)
│       └── debug.rs           # Debug harness: console capture, DOM snapshots, JS eval
├── racket/
│   └── heavymental-core/
│       ├── main.rkt           # Entry point: cells, layout, event/menu dispatch, startup
│       ├── protocol.rkt       # JSON message primitives: send-message!, read-message, make-message
│       ├── cell.rkt           # Reactive cell system: define-cell, cell-set!, cell-ref
│       ├── editor.rkt         # File operations, #lang detection, dirty tracking, pending actions
│       ├── repl.rkt           # REPL lifecycle: start, run-file, restart, language switching
│       ├── lang-intel.rkt     # Check-syntax integration: analysis, offset conversion, intel cache
│       ├── stepper.rkt        # Algebraic stepper using stepper/private/model
│       ├── macro-expander.rkt # Macro expansion tracing using macro-debugger
│       ├── pattern-extractor.rkt # Macro pattern extraction for syntax-rule/syntax-parse-rule
│       ├── extension.rkt      # Extension system: load/unload/reload, namespacing, layout merging
│       ├── ui.rkt             # Declarative UI DSL macro
│       ├── component.rkt      # Custom component registration (define-component)
│       ├── handler-registry.rkt # Auto-handler registration for layout event callbacks
│       ├── keybindings.rkt    # Keybinding management with defaults and overrides
│       ├── settings.rkt       # Settings: defaults, persistence, deep merge
│       ├── theme.rkt          # Theme system: Light/Dark built-in, register custom themes
│       ├── project.rkt        # Project root detection via info.rkt, collection name
│       └── extend/            # #lang heavymental/extend reader for simplified extension authoring
├── frontend/
│   ├── index.html             # Entry point: import map, Monaco worker stub, debug harness
│   ├── core/
│   │   ├── main.js            # Boot sequence: bridge, cells, renderer, components, theme, keybindings
│   │   ├── bridge.js          # Tauri IPC: onMessage(), dispatch(), request/response correlation
│   │   ├── renderer.js        # Layout tree to DOM with ID-based diffing
│   │   ├── cells.js           # Frontend cell registry (signals)
│   │   ├── lang-intel.js      # Intel cache + Monaco providers (diagnostics, hover, definition, completion)
│   │   ├── arrows.js          # SVG Bezier binding arrows overlay
│   │   ├── keybindings.js     # Global keyboard shortcut handler with recording mode
│   │   ├── theme.js           # CSS custom property application
│   │   ├── racket-language.js # Monaco language definition for Racket
│   │   ├── rhombus-language.js # Monaco language definition for Rhombus
│   │   ├── component-registry.js # Dynamic component registration from Racket
│   │   ├── hm-element.js      # Base element with deferred init (WKWebView deadlock avoidance)
│   │   └── primitives/        # hm-* Web Components (editor, terminal, tabs, filetree, etc.)
│   └── vendor/                # Pre-bundled ESM: Lit, Monaco, xterm.js, signals
├── extensions/                # Example extensions (counter, timer, file-watcher, calc-lang, etc.)
└── test/                      # Racket unit tests (rackunit) + E2E test suites
```

## Getting Started

### Prerequisites

- Rust 1.93+ (see `.tool-versions`)
- Racket with `drracket-tool-lib` package installed
- macOS 13+ (WKWebView)

### Development

```bash
# Install Racket dependencies
cd racket/heavymental-core && raco pkg install --auto

# Run in development mode (builds Rust, launches Tauri window, spawns Racket)
cargo tauri dev

# Build release
cargo tauri build

# Run tests
racket test/test-bridge.rkt
racket test/test-phase2.rkt
racket test/test-lang-intel.rkt
racket test/test-stepper.rkt
racket test/test-macro-expander.rkt
racket test/test-extension.rkt
racket test/test-keybindings.rkt
racket test/test-settings.rkt
racket test/test-theme.rkt
```

No frontend build step -- Tauri serves `frontend/` as static files.

## Related Projects

- **[APIAnyware-MacOS](https://github.com/linkuistics/APIAnyware-MacOS)** -- provides the native macOS API bindings that the Linkuistics IDE family will transition to
- **[TestAnyware](https://github.com/linkuistics/TestAnyware)** -- GUI testing for RacketPro in macOS VMs
- **[TheGreatExplainer](https://github.com/linkuistics/TheGreatExplainer)** -- generates documentation and tutorials for APIAnyware's Racket bindings

### Sibling IDEs

Each language in the Linkuistics family has its own dedicated IDE, purpose-built for that language's paradigm:

[ChezPro](https://github.com/linkuistics/ChezPro) ·
[GerbilPro](https://github.com/linkuistics/GerbilPro) ·
[ClozurePro](https://github.com/linkuistics/ClozurePro) ·
[SteelBankPro](https://github.com/linkuistics/SteelBankPro) ·
[HaskellPro](https://github.com/linkuistics/HaskellPro) ·
[IdrisPro](https://github.com/linkuistics/IdrisPro) ·
[MercuryPro](https://github.com/linkuistics/MercuryPro) ·
[PrologPro](https://github.com/linkuistics/PrologPro) ·
[SmalltalkPro](https://github.com/linkuistics/SmalltalkPro)

## License

Apache-2.0
