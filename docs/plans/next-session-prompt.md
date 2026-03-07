# Next Session Prompt

Copy everything below the line into a fresh Claude Code session.

---

We're building HeavyMental — a Racket-driven IDE on Tauri. Read CLAUDE.md for full architecture context.

## What's been completed

**Phases 1-4 are 100% done.** Plus:
- Bottom panel tabs (TERMINAL | PROBLEMS | STEPPER | MACROS)
- Cross-file go-to-definition
- Macro expansion viewer (Phase A): `macro-expander.rkt` + `hm-macro-panel` with tree + detail view
- 10 macro expander tests, all passing

## What we're doing now: Phase B

We have a **fully written implementation plan** at `docs/plans/2026-03-07-phase-b-implementation.md` and a **design doc** at `docs/plans/2026-03-07-phase-b-macro-debugger-design.md`. Read both.

**Phase B replaces the hand-rolled `expand-once` engine with Racket's `macro-debugger/model/*` APIs.** This gives us:
- Structured expansion steps with syntax objects, source locations, and foci (changed sub-expressions)
- Macro identity (which macro fired, where it's defined)
- A stepper view alongside the existing tree view
- Source-level pattern extraction for `syntax-parse` macros

### The 9 tasks (all defined in the implementation plan)

1. **Rewrite expansion engine** — replace `expand-once` loop with `trace/result` + `reductions`, emit `macro:steps` instead of `macro:tree`
2. **Add macro-only filter** — `#:macro-only?` keyword on `start-macro-expander`
3. **Build stepper view frontend** — rewrite `hm-macro-panel` with step list + detail pane + prev/next navigation
4. **Add tree view toggle** — build tree from derivation, add Tree/Stepper toggle in toolbar
5. **Add foci highlighting** — highlight changed sub-expressions in before/after code blocks
6. **Create pattern extractor** — new `pattern-extractor.rkt` module, reads macro source to extract `syntax-parse` patterns
7. **Wire pattern extractor** — emit `macro:pattern` messages for eligible macro steps
8. **Keyboard navigation + polish** — arrow keys, scroll-into-view, escape to clear
9. **Integration test** — run all tests, full manual test, fix edge cases

### Key technical context

- `macro-debugger/model/trace` → `trace/result` gives derivation tree
- `macro-debugger/model/reductions` → `reductions` flattens to step list
- `macro-debugger/model/steps` → `protostep`, `step`, `state` structs with `state-foci`, `step-term1`/`step-term2`
- `macro-debugger/model/deriv` → `mrule`, `base-resolves` for macro identity
- All APIs verified working on this system (Racket 9.1)
- Pattern extraction: source-level parsing of `define-syntax-parse-rule` and `define-syntax-rule` forms

## How to execute

Use `superpowers:subagent-driven-development` to execute the implementation plan. Dispatch one subagent per task, review between tasks. The plan has complete code for each step — follow it closely but adapt as needed when the macro-debugger APIs behave differently than expected.

Start by reading the implementation plan: `docs/plans/2026-03-07-phase-b-implementation.md`
