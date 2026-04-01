# RacketPro

> A Racket IDE from Linkuistics — professional tools for programming language ecosystems.

---

RacketPro is a native macOS IDE for Racket, Rhombus, and language development. It is written in Racket, using [APIAnyware-MacOS](https://github.com/linkuistics/APIAnyware-MacOS) bindings for native macOS APIs, with WebKit as a UI layer and Monaco as the code editor.

Racket is a language-building language. Where other IDEs focus on writing programs, RacketPro is a **language workbench** — optimized for building, testing, and debugging new languages using macros, DSLs, PLT Redex, and SyntaxSpec.

## Why a Dedicated Racket IDE?

DrRacket is excellent for learning, but professional language development demands more: macro expansion visualization, syntax object inspection, #lang-aware intelligence, and seamless Rhombus support alongside Racket. RacketPro provides purpose-built tooling for the kind of work Racket uniquely enables — designing and implementing programming languages.

## Key Features

### Language Workbench

- **Macro expansion visualization** — step through macro transformations, inspect intermediate syntax objects
- **DSL development tools** — first-class support for building and testing domain-specific languages
- **PLT Redex integration** — model and test reduction semantics interactively
- **SyntaxSpec support** — author and debug syntax specifications
- **#lang-aware editing** — automatic language detection and per-language intelligence

### Racket Intelligence

- **Check-syntax integration** — powered by `drracket/check-syntax` for binding arrows, hover information, diagnostics, and go-to-definition
- **Binding arrow visualization** — SVG Bezier curves showing identifier binding relationships across the source
- **Per-language diagnostics** — error reporting adapted to the active `#lang`

### Rhombus Support

- Full editing support for Rhombus, Racket's new surface syntax
- Shared intelligence pipeline — Rhombus files benefit from the same check-syntax infrastructure

### Native macOS Integration

- Built on APIAnyware-MacOS bindings — not Electron, not a web app
- Direct WebKit access from Racket (APIAnyware replaces the need for Tauri)
- Native menus, window management, and system integration

## Architecture

RacketPro uses a message-passing design with Racket driving the application:

```
Frontend (Lit Web Components + @preact/signals-core)
    ↕ WebKit bridge (via APIAnyware bindings)
Racket Core (state, layout, events, language intelligence)
    ↕ APIAnyware-MacOS bindings
macOS platform APIs (AppKit, WebKit, Foundation)
```

**Racket is the brain.** It declares the UI layout, manages application state, handles events, and controls menus. The frontend is a rendering surface — Lit Web Components with Preact signals, no framework, no build step. APIAnyware bindings give Racket direct access to macOS platform APIs, eliminating the need for an intermediary like Tauri.

> **Note:** The current implementation uses a Tauri/Rust bridge during the transition to pure APIAnyware bindings. The architecture above reflects the target design.

### Reactive Cells

Racket declares named cells (`cell:register`) and updates them (`cell:update`). The frontend mirrors them as `@preact/signals-core` signals. Layout properties can reference cells with `"cell:<name>"` syntax, enabling reactive UI updates driven entirely from Racket.

### Layout System

Racket sends a declarative layout tree via `layout:set`. The renderer maps each `type` to an `hm-<type>` custom element. Layout primitives include: `hm-vbox`, `hm-hbox`, `hm-split`, `hm-toolbar`, `hm-statusbar`, `hm-tabs`, `hm-filetree`, `hm-panel-header`, `hm-editor`, `hm-terminal`, `hm-error-panel`.

## Project Structure

```
RacketPro/
├── src-tauri/
│   └── src/
│       ├── bridge.rs          # Rust bridge: spawns Racket, JSON-RPC routing, native menus
│       └── pty.rs             # PTY process management (portable-pty)
├── racket/
│   └── heavymental-core/
│       ├── main.rkt           # Racket entry: layout declaration, event dispatcher
│       ├── protocol.rkt       # JSON message primitives
│       ├── lang-intel.rkt     # Check-syntax integration, binding analysis
│       └── editor.rkt         # File ops, #lang detection
├── frontend/
│   ├── core/
│   │   ├── bridge.js          # Tauri IPC wrapper
│   │   ├── renderer.js        # Layout tree → DOM
│   │   ├── lang-intel.js      # Intel cache + Monaco providers
│   │   └── primitives/        # hm-* Web Components (editor, terminal, etc.)
│   └── vendor/                # Pre-bundled ESM: Lit, Monaco, xterm.js, signals
└── test/                      # Racket tests (rackunit)
```

## Getting Started

### Prerequisites

- Rust (see `.tool-versions`)
- Racket with `drracket-tool-lib` package installed
- macOS (WKWebView)

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
```

No frontend build step — Tauri serves `frontend/` as static files.

## Related Projects

- **[APIAnyware-MacOS](https://github.com/linkuistics/APIAnyware-MacOS)** — provides the native macOS API bindings that RacketPro is built on
- **[TestAnyware](https://github.com/linkuistics/TestAnyware)** — GUI testing for RacketPro in macOS VMs
- **[TheGreatExplainer](https://github.com/linkuistics/TheGreatExplainer)** — generates documentation and tutorials for APIAnyware's Racket bindings

### Sibling IDEs

Each language in the APIAnyware family has its own dedicated IDE, purpose-built for that language's paradigm:

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
