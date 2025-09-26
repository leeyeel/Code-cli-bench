#!/usr/bin/env bash
# ./run_headless.sh -t tests -s claude
set -euo pipefail

ROOT_DIR="$(pwd)"
TEST_DIR="tests"
SHOW="claude"
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
PYWEN_CMD="${PYWEN_CMD:-pywen}"

usage() {
  echo "Usage: $0 [-t TEST_DIR] [-s SHOW]"
  echo "  SHOW: claude | pywen | both | none"
  exit 1
}

while getopts ":t:s:h" opt; do
  case "$opt" in
    t) TEST_DIR="$OPTARG" ;;
    s) SHOW="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

case "$SHOW" in
  claude|pywen|both|none) ;;
  *) echo "Invalid SHOW=$SHOW"; usage ;;
esac

hr()    { printf '\n\033[1;36m%s\033[0m\n' "────────────────────────────────────────────────────────"; }
title() { printf '\033[1;33m%s\033[0m\n' "$*"; }

prefix_pipe() {
  local tag="$1"
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL sed -u "s/^/[$tag] /"
  else
    sed -u "s/^/[$tag] /"
  fi
}

shopt -s nullglob
tests=("$TEST_DIR"/*.md)
if (( ${#tests[@]} == 0 )); then
  echo "No *.txt found in $TEST_DIR"
  exit 1
fi

CLAUDE_ROOT="$ROOT_DIR/output/headless/claude"
PYWEN_ROOT="$ROOT_DIR/output/headless/pywen"
mkdir -p "$CLAUDE_ROOT" "$PYWEN_ROOT"
export PYWEN_TRAJECTORY_DIR="$PYWEN_ROOT"
export CLAUDE_TRAJECTORY_DIR="$CLAUDE_ROOT"

"$PYWEN_CMD" --create-config

for f in "${tests[@]}"; do
  case_id="$(basename "$f" .txt)"
  prompt="$(cat "$f")"

  hr
  title "[CASE $case_id] $(date -Iseconds)"
  echo "Prompt file: $f"
  echo -e "Prompt: $prompt\n"

  cl_pid=""; py_pid=""

  case "$SHOW" in
    claude)
      title ">>> Claude Code (visible) & Pywen (silent, parallel)"
      (
        cd "$CLAUDE_ROOT" || exit 1
        exec "$CLAUDE_CMD" -p "$prompt" --dangerously-skip-permissions
      ) | prefix_pipe "CLAUDE" &
      cl_pid=$!

      (
        cd "$PYWEN_ROOT" || exit 1
        exec "$PYWEN_CMD" "$prompt"
      ) >/dev/null 2>&1 & 
      py_pid=$!
      ;;

    pywen)
      title ">>> Claude Code (silent, parallel) & Pywen (visible)"
      (
        cd "$CLAUDE_ROOT" || exit 1
        exec "$CLAUDE_CMD" -p "$prompt" --dangerously-skip-permissions
      ) >/dev/null 2>&1 &
      cl_pid=$!

      (
        cd "$PYWEN_ROOT" || exit 1
        exec "$PYWEN_CMD" "$prompt"
      ) | prefix_pipe "PYWEN" &
      py_pid=$!
      ;;

    both)
      title ">>> Claude Code & Pywen (both visible, parallel)"
      (
        cd "$CLAUDE_ROOT" || exit 1
        exec "$CLAUDE_CMD" -p "$prompt" --dangerously-skip-permissions
      ) | prefix_pipe "CLAUDE" &
      cl_pid=$!

      (
        cd "$PYWEN_ROOT" || exit 1
        exec "$PYWEN_CMD" "$prompt"
      ) | prefix_pipe "PYWEN" &
      py_pid=$!
      ;;

    none)
      title ">>> Claude Code & Pywen (both silent, parallel)"
      (
        cd "$CLAUDE_ROOT" || exit 1
        exec "$CLAUDE_CMD" -p "$prompt" --dangerously-skip-permissions
      ) >/dev/null 2>&1 &
      cl_pid=$!

      (
        cd "$PYWEN_ROOT" || exit 1
        exec "$PYWEN_CMD" "$prompt"
      ) >/dev/null 2>&1 &
      py_pid=$!
      ;;
  esac

  if [[ -n "${cl_pid}" ]]; then wait "${cl_pid}" || true; fi
  if [[ -n "${py_pid}" ]]; then wait "${py_pid}" || true; fi

done

hr
title "ALL DONE."

