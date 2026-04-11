#!/bin/zsh
# Usage: ./run.sh
# Exit each phase with /exit to advance. Ctrl+C to stop the cycle.

DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$DIR"
while [ ! -d "$PROJECT/.git" ] && [ "$PROJECT" != "/" ]; do
  PROJECT="$(dirname "$PROJECT")"
done
SESSION="$(basename "$PROJECT")"

while true; do
  PHASE=$(cat "$DIR/phase.md" 2>/dev/null || echo work)
  PROMPT=$(cat "$DIR/prompt-$PHASE.md")
  echo "\n=== $PHASE ==="
  (cd "$PROJECT" && claude --allow-dangerously-skip-permissions -n "$PHASE-$SESSION" "$PROMPT")
done
