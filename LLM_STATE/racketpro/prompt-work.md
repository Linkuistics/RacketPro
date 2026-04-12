You are working on RacketPro, a Racket-driven IDE built on Tauri.

Read these files for context:
- {{PROJECT}}/README.md (project conventions, architecture, commands)
- {{DEV_ROOT}}/LLM_CONTEXT/backlog-plan.md (the backlog plan format and phase cycle spec)
- {{PLAN}}/backlog.md (task backlog)
- {{PLAN}}/memory.md (distilled learnings)

Follow the WORK phase from backlog-plan.md:
1. Read backlog.md and memory.md
2. Display a summary of the current backlog (title, status, and priority for
   each task). Then ask the user if they have any input on which task to work
   on next. Wait for the user's response. If they have a preference, work on
   that task; otherwise pick the best next task.
3. Implement the task using TDD where applicable
4. Run tests: for f in test/test-*.rkt; do racket "$f"; done
5. Verify with: cargo tauri dev (if UI changes)
6. Record results on the task in backlog.md
7. Append a session log entry to {{PLAN}}/session-log.md
8. Write reflect to {{PLAN}}/phase.md
9. Stop — do not pick another task, do not reflect, do not triage

Key conventions from CLAUDE.md:
- Racket message types use colon-separated namespaces (cell:update, intel:diagnostics, etc.)
- Web Components are prefixed hm- in frontend/core/primitives/
- No build step — native ES modules with import map
- Tests are Racket-only (rackunit)
- Racket provides are explicit — every exported function must be in the provide list
- Title separator is em-dash, not hyphen
