---
title: RacketPro
---

RacketPro is a native macOS IDE for Racket, Rhombus, and language development. Racket is the application brain — it declares the UI layout, manages state, handles events, and controls menus. A Rust/Tauri bridge spawns the Racket process, routes JSON-RPC messages over stdin/stdout, and provides OS-level services (PTY, filesystem, native dialogs, native menus). The frontend is a thin rendering surface built with Lit Web Components, Preact signals, Monaco, and xterm.js. No build step.

Racket is a language-building language. Where other IDEs focus on writing programs, RacketPro is a language workbench — optimized for building, testing, and debugging new languages using macros and DSLs. DrRacket is excellent for learning, but professional language development demands more: macro expansion visualization, syntax object inspection, `#lang`-aware intelligence, and first-class Rhombus support.

Key language-workbench features: macro expansion tracing via `macro-debugger` with step-by-step derivation trees; an algebraic stepper backed by Racket's `stepper/private/model`; `#lang`-aware editing with per-language REPL switching; and `drracket/check-syntax` integration for binding arrows, hover, go-to-definition, diagnostics, and completion. Rhombus files share the same intelligence pipeline automatically.

The extension system lets users add IDE features in Racket itself. Extensions are Racket modules using `define-extension`, contributing reactive cells, UI panels, menu items, and lifecycle hooks. A `#lang heavymental/extend` reader simplifies authoring. Extensions live-reload on save with error isolation.

The three-layer architecture — Racket Core ↔ Rust Bridge ↔ Web Frontend — keeps language intelligence in Racket, OS services in Rust, and rendering in the browser layer. Racket drives reactive UI state via named cells mirrored as Preact signals on the frontend; layout is a declarative tree sent via `layout:set` and diffed by stable node IDs.
