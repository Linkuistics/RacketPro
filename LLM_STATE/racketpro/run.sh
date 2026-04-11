#!/bin/zsh
# Usage: ./run.sh [--dangerously-skip-permissions]
# /exit advances to the next phase. Ctrl+C quits the cycle.

DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$DIR"
while [ ! -d "$PROJECT/.git" ] && [ "$PROJECT" != "/" ]; do
  PROJECT="$(dirname "$PROJECT")"
done
SESSION="$(basename "$PROJECT")"

CLAUDE_ARGS=(--allow-dangerously-skip-permissions)
for arg in "$@"; do
  case "$arg" in
    --dangerously-skip-permissions)
      CLAUDE_ARGS+=(--dangerously-skip-permissions)
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: ./run.sh [--dangerously-skip-permissions]" >&2
      exit 1
      ;;
  esac
done

while true; do
  PHASE=$(cat "$DIR/phase.md" 2>/dev/null || echo work)
  PROMPT=$(cat "$DIR/prompt-$PHASE.md")
  echo "\n=== $PHASE ==="
  (cd "$PROJECT" && claude $CLAUDE_ARGS -n "$PHASE-$SESSION" "$PROMPT")
  [ $? -ne 0 ] && break
done
