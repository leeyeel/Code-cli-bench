#!/usr/bin/env bash
#   Ctrl-b S   切换“同步输入”开/关
#   Ctrl-b ←/→ 在左右 pane 切换焦点
#   :kill-session 或 Ctrl-d 退出

set -euo pipefail

SESSION="${SESSION:-PYWEN_CLAUDE_DUAL_VIEW}"
TEST_DIR="tests"
ROOT_DIR="$(pwd)"
CLAUDE_OUT_DIR="$ROOT_DIR/output/interactive/claude"
PYWEN_OUT_DIR="$ROOT_DIR/output/interactive/pywen"
export PYWEN_TRAJECTORY_DIR="$PYWEN_OUT_DIR"
export CLAUDE_TRAJECTORY_DIR="$CLAUDE_OUT_DIR"
DELAY=5
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
PYWEN_CMD="${PYWEN_CMD:-pywen}"

FIFO_DIR="${FIFO_DIR:-/tmp/agent-done}"
CLAUDE_FIFO="$FIFO_DIR/claude.done"
PYWEN_FIFO="$FIFO_DIR/pywen.done"

PASTE_BRACKETED=1
CLAUDE_PASTE_BRACKETED="${CLAUDE_PASTE_BRACKETED:-1}"

ENTER_DELAY=2
ENTER_DELAY2=1
READY_DELAY=0.5
DEBUG=${DEBUG:-0}

mkdir -p "$FIFO_DIR"
[[ -p "$CLAUDE_FIFO" ]] || mkfifo "$CLAUDE_FIFO"
[[ -p "$PYWEN_FIFO"  ]] || mkfifo "$PYWEN_FIFO"

exec {CLAUDE_RD}<>"$CLAUDE_FIFO"
exec {PYWEN_RD}<>"$PYWEN_FIFO"

cleanup() {
  exec {CLAUDE_RD}>&- || true
  exec {PYWEN_RD}>&- || true
  rm -f "$CLAUDE_FIFO" "$PYWEN_FIFO" 2>/dev/null || true
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage: $0 [-t TEST_DIR] [-d SECONDS] [-s] [-v]
  -t TEST_DIR   测试用例目录（默认：$TEST_DIR）
  -d SECONDS    自动模式下每条用例提交后等待秒数（默认：$DELAY）
  -s            step 模式：每条用例提交前等待你按 Enter
  -v            详细模式：显示调试信息
环境变量可覆盖：
  SESSION, CLAUDE_CMD, PYWEN_CMD, DEBUG
EOF
  exit 1
}

while getopts ":t:d:svh" opt; do
  case "$opt" in
    t) TEST_DIR="$OPTARG" ;;
    d) DELAY="$OPTARG" ;;
    s) STEP=1 ;;
    v) DEBUG=1 ;;
    h|*) usage ;;
  esac
done

"$PYWEN_CMD" --create-config

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" \
    "bash -lc 'mkdir -p \"$CLAUDE_OUT_DIR\" && cd \"$CLAUDE_OUT_DIR\" && \"$CLAUDE_CMD\" --dangerously-skip-permissions || true; exec bash -li'"

  tmux split-window -h -t "$SESSION" \
    "bash -lc 'mkdir -p \"$PYWEN_OUT_DIR\" && cd \"$PYWEN_OUT_DIR\" && \"$PYWEN_CMD\" || true; exec bash -li'"

  tmux select-layout -t "$SESSION" even-horizontal
  tmux set-option -t "$SESSION" mouse on
  tmux set-option -t "$SESSION" pane-border-status top
  tmux set-option -t "$SESSION" pane-border-format " #[bold]#P » #{pane_current_command}"
  tmux set-option -t "$SESSION" status-position top
fi

get_pane_id_by_cmd() {
  local pat="$1"
  tmux list-panes -t "$SESSION" -F '#{pane_id} #{pane_current_command}' \
    | awk -v pat="$pat" '$2 ~ pat {print $1; exit}'
}

CLAUDE_PANE="$(get_pane_id_by_cmd '^claude')"
PYWEN_PANE="$(get_pane_id_by_cmd '^pywen')"

CLAUDE_PANE="${CLAUDE_PANE:-$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | sed -n '1p')}"
PYWEN_PANE="${PYWEN_PANE:-$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | sed -n '2p')}"

ready_pane() {
  local pane="$1"
  tmux if -t "$pane" -F '#{pane_in_mode}' 'send-keys -t "#{pane_id}" -X cancel' ''
  tmux send-keys -t "$pane" C-m
  sleep "${READY_DELAY:-0.5}"
}

feed_line_to_pane() {
  local pane="$1"; local line="$2"
  ready_pane "$pane"
  tmux send-keys -t "$pane" -l -- "$line"
  sleep 0.3
  tmux send-keys -t "$pane" C-m
  sleep 0.2
}

feed_file_to_pane() {
  local pane="$1"; local file="$2"; local is_claude="$3"
  local file_size=$(wc -l < "$file")
  
  [[ "$DEBUG" == "1" ]] && echo "    Feeding $file_size lines to pane $pane" >&2
  
  ready_pane "$pane"
  
  # Load file content into tmux buffer
  { cat "$file"; printf '\n'; } | tmux load-buffer -t "$SESSION" -

  # Use bracketed paste for better multi-line handling
  if [[ "$is_claude" == "1" && "$CLAUDE_PASTE_BRACKETED" == "1" ]]; then
    [[ "$DEBUG" == "1" ]] && echo "    Using bracketed paste for Claude" >&2
    tmux paste-buffer -t "$pane" -p
  elif [[ "$is_claude" != "1" && "$PASTE_BRACKETED" == "1" ]]; then
    [[ "$DEBUG" == "1" ]] && echo "    Using bracketed paste for Pywen" >&2
    tmux paste-buffer -t "$pane" -p
  else
    [[ "$DEBUG" == "1" ]] && echo "    Using regular paste" >&2
    tmux paste-buffer -t "$pane"
  fi

  # Dynamic delay based on content size
  local content_delay=$(( file_size > 10 ? ENTER_DELAY + 1 : ENTER_DELAY ))
  [[ "$DEBUG" == "1" ]] && echo "    Waiting ${content_delay}s for content processing" >&2
  sleep "$content_delay"
  
  # Send single Enter to execute
  tmux send-keys -t "$pane" C-m
  
  # Brief pause after execution
  sleep 0.5
}

normalize_line() {
  printf "%s" "$1" | tr -d '\r' | awk '{$1=$1;print}'
}

verify_pane_ready() {
  local pane="$1"
  local max_wait=5
  local count=0
  
  while (( count < max_wait )); do
    if tmux capture-pane -t "$pane" -p | tail -1 | grep -qE '[>$#]\s*$'; then
      return 0
    fi
    sleep 0.5
    ((count++))
  done
  
  echo "Warning: Pane $pane may not be ready" >&2
  return 1
}

read_try_line() {
  local fd="$1" out
  if IFS= read -r -t 0.1 -u "$fd" out; then
    printf "%s" "$out"
    return 0
  else
    return 1
  fi
}

wait_both_done() {
  local case_id="$1"
  local need_claude=1 need_pywen=1
  local line norm

  while (( need_claude==1 || need_pywen==1 )); do
    if (( need_claude==1 )); then
      if line="$(read_try_line "$CLAUDE_RD")"; then
        norm="$(normalize_line "$line")"
        [[ "$norm" =~ ^${case_id}[[:space:]]+DONE$ ]] && need_claude=0
      fi
    fi
    if (( need_pywen==1 )); then
      if line="$(read_try_line "$PYWEN_RD")"; then
        norm="$(normalize_line "$line")"
        [[ "$norm" =~ ^${case_id}[[:space:]]+DONE$ ]] && need_pywen=0
      fi
    fi
  done
}

shopt -s nullglob
tests=( "$TEST_DIR"/*.txt )
(( ${#tests[@]} > 0 )) || { echo "No *.txt in $TEST_DIR"; exec tmux attach -t "$SESSION"; }

echo "会话：$SESSION"
echo "Claude pane: $CLAUDE_PANE"
echo "Pywen  pane: $PYWEN_PANE"
echo "开始投喂 tests/*.txt（定向到两个 pane）..."
sleep 1

for f in "${tests[@]}"; do
  case_id="$(basename "$f")"
  printf "\n[CASE] %s\n" "$case_id"

  if [[ "${STEP:-0}" == "1" ]]; then
    read -rp "Press Enter to feed $case_id ..."
  fi

  # Set case ID in both panes
  [[ "$DEBUG" == "1" ]] && echo "  -> Setting CASE_ID in both panes" >&2
  feed_line_to_pane "$CLAUDE_PANE" "CASE_ID=$case_id"
  sleep 0.3
  feed_line_to_pane "$PYWEN_PANE"  "CASE_ID=$case_id"
  sleep 0.3

  # Feed test content
  echo "  -> Feeding to Claude pane..."
  if feed_file_to_pane "$CLAUDE_PANE" "$f" 1; then
    [[ "$DEBUG" == "1" ]] && echo "    Claude feed successful" >&2
  else
    echo "    Warning: Claude feed may have failed" >&2
  fi
  
  echo "  -> Feeding to Pywen pane..."
  if feed_file_to_pane "$PYWEN_PANE"  "$f" 0; then
    [[ "$DEBUG" == "1" ]] && echo "    Pywen feed successful" >&2
  else
    echo "    Warning: Pywen feed may have failed" >&2
  fi

  [[ "$DEBUG" == "1" ]] && echo "  -> Waiting for both agents to complete" >&2
  wait_both_done "$case_id"
  
  echo "[DONE] $case_id"

  if [[ "${STEP:-0}" != "1" ]]; then
    sleep "$DELAY"
  fi 
done

echo -e "\n全部用例完成，进入会话（Ctrl-b S 切同步输入，Ctrl-b ←/→ 切 pane）..."
tmux setw -t "$SESSION" synchronize-panes on
tmux bind-key S setw synchronize-panes
feed_line_to_pane "$CLAUDE_PANE" "/quit"
feed_line_to_pane "$PYWEN_PANE"  "/quit"
sleep 1
tmux kill-session -t "$SESSION" 2>/dev/null || true

