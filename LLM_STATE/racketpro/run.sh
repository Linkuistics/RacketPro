#!/bin/zsh
# RacketPro — Racket-driven IDE
# Usage: ./run.sh
# Exit each phase with /exit to advance. Ctrl+C to stop the cycle.

DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$DIR/../.." && pwd)"

while true; do
  # Phase 1: WORK
  echo "\n=== WORK PHASE ==="
  (cd "$PROJECT" && claude "You are working on RacketPro, a Racket-driven IDE built on Tauri.

Read these files for context:
- CLAUDE.md (project conventions, architecture, commands)
- ../LLM_CONTEXT/backlog-plan.md (the backlog plan format and phase cycle spec)
- LLM_STATE/racketpro/plan.md (task backlog)
- LLM_STATE/racketpro/memory.md (distilled learnings)

Follow the WORK phase from backlog-plan.md:
1. Read plan.md and memory.md
2. Pick the best next task (consider dependencies, priority, momentum)
3. Implement the task using TDD where applicable
4. Run tests: for f in test/test-*.rkt; do racket \"\$f\"; done
5. Verify with: cargo tauri dev (if UI changes)
6. Record results on the task in plan.md
7. Append a session log entry to LLM_STATE/racketpro/session-log.md
8. Stop — do not pick another task, do not reflect, do not triage

Key conventions from CLAUDE.md:
- Racket message types use colon-separated namespaces (cell:update, intel:diagnostics, etc.)
- Web Components are prefixed hm- in frontend/core/primitives/
- No build step — native ES modules with import map
- Tests are Racket-only (rackunit)
- Racket provides are explicit — every exported function must be in the provide list
- Title separator is em-dash, not hyphen")

  # Phase 2: REFLECT
  echo "\n=== REFLECT PHASE ==="
  (cd "$PROJECT" && claude "You are reflecting on a work session for RacketPro.

Read these files:
- ../LLM_CONTEXT/backlog-plan.md (the backlog plan format and reflect phase spec)
- LLM_STATE/racketpro/session-log.md (latest entry)
- LLM_STATE/racketpro/memory.md (current distilled learnings)

Follow the REFLECT phase from backlog-plan.md:
1. Read the latest session-log.md entry and current memory.md
2. For each learning in the session log, ask:
   - Is this new? Add a memory entry
   - Does this sharpen an existing entry? Update it
   - Does this contradict an existing entry? Replace it
   - Does this make an existing entry redundant? Remove it
3. Prune aggressively — memory.md should contain only what is currently true and useful
4. Stop after updating memory.md

Do NOT read plan.md — avoid task-oriented thinking during reflection.")

  # Phase 3: TRIAGE
  echo "\n=== TRIAGE PHASE ==="
  (cd "$PROJECT" && claude "You are triaging the task backlog for RacketPro.

Read these files:
- ../LLM_CONTEXT/backlog-plan.md (the backlog plan format and triage phase spec)
- LLM_STATE/racketpro/plan.md (task backlog)
- LLM_STATE/racketpro/memory.md (distilled learnings)

Follow the TRIAGE phase from backlog-plan.md:
1. Review each task: still relevant? priority changed? needs splitting?
2. Add new tasks discovered during work or implied by new learnings
3. Remove tasks that are no longer relevant
4. Reprioritize based on what has been learned
5. Stop after updating plan.md

Do NOT read session-log.md — use only the distilled memory for context.")

  echo "\n--- Cycle complete. Enter to continue, Ctrl+C to stop ---"
  read
done
