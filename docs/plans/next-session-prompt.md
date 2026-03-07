# Next Session Prompt

Copy everything below the line into a fresh Claude Code session.

---

We're building HeavyMental — a Racket-driven IDE on Tauri. Read CLAUDE.md for full architecture context.

## What's been completed

**Phases 1–4 are 100% done**, plus all enhancement rounds:

- **Phase A** (Quick Wins): Bottom panel tabs, cross-file go-to-definition, macro expansion viewer
- **Phase B** (Macro Debugger): Full rewrite with `macro-debugger/model/*` APIs — structured steps, foci highlighting, tree+stepper dual view, `syntax-parse` pattern extraction, keyboard navigation
- **Rhombus Language Support**: Monaco providers for both racket/rhombus, language-aware REPL (`racket -I rhombus`), auto-restart on language switch, stepper guarded with friendly error, macro debugger verified working with Rhombus, `rhombus` package installed

## Current state

- 8 test files, all passing: `test-bridge`, `test-phase2`, `test-phase4`, `test-lang-intel`, `test-stepper`, `test-macro-expander`, `test-pattern-extractor`, `test-rhombus`
- Rhombus is installed (`raco pkg install rhombus`) and `check-syntax` works on `#lang rhombus` files
- The stepper is Racket-only (guarded with error message for `.rhm` files)
- Pattern extractor uses S-expression `read` — can't parse shrubbery syntax for Rhombus macros

## What's remaining to fully close out Phase 4

Per the original design doc (`docs/plans/2026-03-04-mrracket-design.md`, line 194), Phase 4 targets:

> Stepper with expression highlighting. Binding/substitution display. Macro expansion viewer. SyntaxSpec pattern visualization. **Demo**: Step through Rhombus, debug SyntaxSpec macros.

### Items not yet done:

1. **SyntaxSpec pattern visualization** — The pattern extractor works for `syntax-parse` and `syntax-rules` macros, but doesn't handle SyntaxSpec patterns yet. SyntaxSpec is a newer macro definition system; need to research its AST/source format and extend `pattern-extractor.rkt`.

2. **Demo: "Step through Rhombus"** — Currently guarded with an error. The stepper engine (`stepper/private/model`) uses Racket reduction semantics. Options:
   - Accept the limitation (Rhombus stepper is a future project)
   - Or investigate whether the stepper can work with Rhombus's expansion pipeline

3. **Demo: "Debug SyntaxSpec macros"** — The macro debugger works generically via `trace/result`, so SyntaxSpec macros do get expanded. But the *pattern visualization* (showing which pattern matched) doesn't work for SyntaxSpec yet.

### Pragmatic recommendation

Items 2 and 3 depend on upstream Rhombus/SyntaxSpec maturity. A pragmatic Phase 4 close-out would:
- Document the limitations clearly
- Ensure error messages are friendly
- Move SyntaxSpec pattern visualization to Phase 5 (DSLs + Extensions)
- Mark Phase 4 as complete

## What's next: Phase 5 — DSLs + Extensions (Liveness)

Per the design doc:
> `#lang heavymental/ui` and `#lang heavymental/component`. Extension API. Live reload of IDE modules. Cell/layout inspector. **Demo**: Write an extension inside HeavyMental that adds a panel, live.

Key decisions to make:
- Start with `#lang heavymental/ui` DSL or the extension API?
- Use Racket or Rhombus for the DSL surface?
- Cell/layout inspector: separate panel or integrated into devtools?

## Key files to read first

| File | Why |
|------|-----|
| `CLAUDE.md` | Full architecture + conventions |
| `docs/plans/2026-03-04-mrracket-design.md` | 6-phase roadmap |
| `racket/heavymental-core/main.rkt` | Event dispatch, layout, state |
| `racket/heavymental-core/macro-expander.rkt` | Current macro debugger implementation |
| `racket/heavymental-core/pattern-extractor.rkt` | Pattern extraction (syntax-parse only) |
| `frontend/core/primitives/macro-panel.js` | Macro panel UI (tree + stepper views) |

## Test commands

```bash
# Run all tests
racket test/test-bridge.rkt && racket test/test-phase2.rkt && racket test/test-phase4.rkt && racket test/test-lang-intel.rkt && racket test/test-stepper.rkt && racket test/test-macro-expander.rkt && racket test/test-pattern-extractor.rkt && racket test/test-rhombus.rkt

# Run the app
cargo tauri dev
```
