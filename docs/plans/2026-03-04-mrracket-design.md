# MrRacket: A Racket-Driven IDE

**Date**: 2026-03-04
**Status**: Approved

## Vision

MrRacket is a DrRacket-class IDE built on Tauri, where Racket is the orchestrator and the native app is a rendering surface. Inspired by Smalltalk's philosophy: the IDE is the language runtime, extensible from within itself.

The project has two layers:
1. **A Racket-to-native-app bridge framework** — Racket controls Tauri/WebView for building desktop apps
2. **MrRacket IDE** — the first application built on that framework

Primary languages: Racket, Rhombus, and SyntaxSpec.

## Architecture

### Core Principle: Racket Drives Everything

```
Frontend (WebView)           → Rendering surface (Lit Web Components, no framework)
Rust Backend (Tauri)         → Thin bridge (process management, PTY, OS plumbing)
Racket Core                  → The brain (UI model, IDE logic, extensions)
```

Racket tells the frontend what to render. The frontend sends user events back to Racket. Rust routes messages and provides native OS access. No Racket semantics live in Rust.

### Communication: JSON-RPC over stdin/stdout

Bidirectional channel between Racket and Rust:

**Racket → Rust (commands):**
- Window management: create, close, set properties
- OS integration: menus, dialogs, tray, clipboard, notifications
- WebView control: emit events, eval JS
- File system: read, write, watch
- Process management: PTY create/write/resize, spawn/kill

**Rust → Racket (events):**
- User interactions: clicks, input, menu selections
- File system changes
- PTY output
- Window lifecycle events

### Reactive Model: Signal-Based Cells

No virtual DOM. Racket works with reactive cells that map directly to JS signals.

```
Racket cell  →  register via bridge  →  JS signal  →  DOM update
Racket set-cell!  →  update via bridge  →  signal.value = x  →  surgical DOM update
User event  →  bridge event  →  Racket dispatch
```

Layout is declared once (or on structural changes). Cell updates are surgical — only changed values cross the bridge.

### Frontend: Lit Web Components, Zero Build

No framework. No bundler. The frontend is:
- `@preact/signals-core` (1.8KB) for reactivity
- Lit Web Components for UI primitives
- Monaco Editor (standalone ESM) for code editing
- xterm.js (standalone ESM) for terminal
- Plain CSS with custom properties for theming
- All served as native ES modules — no compilation step

Everything is dynamic at runtime. Racket can:
- Register new Web Components by injecting Lit class definitions
- Inject arbitrary JS or load WASM for performance
- Modify the UI tree, theme, menus, and any cell at any time

### Primitive Component Set

Built-in Lit components (prefixed `mr-`):

| Category | Components |
|----------|-----------|
| Layout | mr-hbox, mr-vbox, mr-grid, mr-stack, mr-scroll, mr-split |
| Content | mr-text, mr-heading, mr-code, mr-icon, mr-markdown, mr-image |
| Input | mr-button, mr-input, mr-checkbox, mr-select, mr-slider |
| Data | mr-table, mr-list, mr-tree |
| Rich | mr-editor (Monaco), mr-terminal (xterm), mr-svg-canvas |
| Chrome | mr-toolbar, mr-tabbar, mr-statusbar, mr-panel, mr-dialog |

Racket composes these freely into new "components" — components are just functions returning primitive trees.

## Language-Oriented Architecture

### Strategy: Racket Core, Rhombus Surface DSLs

```
User-facing DSLs (Rhombus/SyntaxSpec):
  #lang mrracket/ui         — declarative layout
  #lang mrracket/component  — Lit component authoring (v2+)
  #lang mrracket/extend     — extension API
  #lang mrracket/theme      — styling

Core libraries (stable Racket):
  mrracket/cell       — reactive cell system
  mrracket/protocol   — JSON-RPC serialization
  mrracket/runtime    — process lifecycle
  mrracket/bridge     — Rust communication
```

Core in Racket for stability. DSLs in Rhombus for the authoring experience. SyntaxSpec powers the macro layer.

### JS-as-DSL Roadmap

| Version | Approach |
|---------|----------|
| v1 | Heredoc strings with syntax highlighting |
| v2 | `#lang mrracket/js` — validated JS syntax |
| v3 | `#lang mrracket/component` — Rhombus→Lit compiler |

## IDE Features (DrRacket Parity)

### Check Syntax
Binding arrows, rename refactoring, unused-variable highlighting. Driven by `drracket/check-syntax` on the Racket side, rendered as SVG/Canvas overlay on Monaco.

### Language-Aware Coloring
Syntax highlighting driven by the Racket expander, not just regex. `#lang` line detected → editor mode switches automatically. Custom tokenizer for Rhombus shrubbery notation.

### Stepper
Step through Racket/Rhombus evaluation expression by expression. Uses Racket's stepper infrastructure. Sends structured data (current expression location, bindings, substitution steps) as cell updates. Frontend highlights in Monaco and shows bindings in a panel.

### Macro Debugger / SyntaxSpec Visualizer
Visualize macro expansion steps. For SyntaxSpec: show pattern matching, template instantiation, marks. Multi-step navigation through expansion.

### REPL
xterm.js terminal connected to Racket via PTY. Run button evaluates definitions and drops into REPL with the same namespace. Rich output overlay for images, test results, structured data.

## Debugging Layers

1. **Racket Debugging** (primary) — Stepper, macro debugger, Check Syntax, error traces
2. **Bridge Debugging** (IDE dev) — Protocol inspector, cell inspector, layout inspector
3. **WebView DevTools** (component dev) — Chromium DevTools with MrRacket cell bindings panel

## Racket Integration

- System-installed Racket (found on PATH)
- LSP via racket-langserver for completions/diagnostics
- Subprocess for REPL via PTY
- Custom `mrracket-server` Racket package for Check Syntax, stepper, expansion

## Liveness Model

| Concept | Implementation |
|---------|---------------|
| Workspace state | Directory of Racket/Rhombus modules |
| Live editing | Edit module → re-evaluate → UI updates in-place |
| Self-modification | IDE's own modules editable within itself |
| Extension loading | `require` a module → commands/panels available immediately |
| Persistence | File-based (not image-based), loaded on startup |

## Project Structure

```
mrracket/
├── src-tauri/               # Rust bridge (compiles)
│   ├── src/
│   │   ├── main.rs
│   │   ├── bridge.rs        # JSON-RPC ↔ Tauri IPC
│   │   ├── pty.rs           # PTY management
│   │   └── fs.rs            # File operations
│   └── Cargo.toml
├── frontend/                # Served as-is, no build
│   ├── index.html           # Bootstrap (~50 lines)
│   ├── core/
│   │   ├── bridge.js        # Tauri IPC ↔ Racket
│   │   ├── cells.js         # Signal-based cell registry
│   │   ├── renderer.js      # Primitive tree → DOM
│   │   └── primitives/      # Built-in Lit components
│   ├── vendor/              # Local copies (Lit, Monaco, xterm)
│   └── style/               # CSS
├── racket/
│   ├── mrracket-core/       # Bridge library (Racket)
│   ├── mrracket-ui/         # UI DSL (Rhombus)
│   ├── mrracket-extend/     # Extension API
│   └── mrracket-ide/        # The IDE application
└── docs/
```

## Build Phases

### Phase 1: The Bridge (Foundation)
Tauri app with no-build frontend. Rust bridge spawns Racket, JSON-RPC communication. Racket cell system. Lit primitive components. **Demo**: Racket creates a window with a reactive counter.

### Phase 2: Editor + REPL (Minimum IDE)
Monaco editor component. xterm.js terminal with PTY. File open/save. Basic Racket syntax highlighting. Run button. **Demo**: Edit a .rkt file, run it, see output.

### Phase 3: Language Intelligence
racket-langserver integration. Check Syntax arrows. #lang detection. Rhombus syntax highlighting. Error traces. **Demo**: Full Check Syntax, go-to-definition, Rhombus coloring.

### Phase 4: Stepper + Macro Debugger
Stepper with expression highlighting. Binding/substitution display. Macro expansion viewer. SyntaxSpec pattern visualization. **Demo**: Step through Rhombus, debug SyntaxSpec macros.

### Phase 5: DSLs + Extensions (Liveness)
`#lang mrracket/ui` and `#lang mrracket/component`. Extension API. Live reload of IDE modules. Cell/layout inspector. **Demo**: Write an extension inside MrRacket that adds a panel, live.

### Phase 6: Polish + Distribution
Native menus, tray, shortcuts (Racket-driven). Theming. Multi-file projects. Settings. Packaging for macOS.
