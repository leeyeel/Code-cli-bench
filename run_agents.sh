#!/usr/bin/env bash
# Requirements: yq (https://github.com/mikefarah/yq)
set -euo pipefail

CONFIG="agents.yaml"
AGENTS="" 
TEST_PATH=""
DRY_RUN=0
MAX_JOBS=0

usage() {
  cat <<'USAGE'
Usage: run_agents.sh [-c CONFIG.yaml] [-a "agent1,agent2"] [-t TEST_PATH] [-j N] [-n]

Options:
  -c FILE   YAML config file (default: agents.yaml)
  -a LIST   Comma-separated agent names to run; default = all agents in YAML
  -t PATH   Test path (file or directory). If directory, iterate matching files.
  -j N      Max number of agents to run in parallel (default: number of agents)
  -n        Dry run (print what would be executed without running)

Notes:
- Each agent runs its own init (if configured) ONCE, then executes tests SERIALLY.
- Different agents run IN PARALLEL up to -j N.
- YAML supports 'env:NAME' to copy current env and ${VAR:-default} expansions in args/init.
USAGE
  exit 1
}

while getopts ":c:a:t:j:nh" opt; do
  case "$opt" in
    c) CONFIG="$OPTARG" ;;
    a) AGENTS="$OPTARG" ;;
    t) TEST_PATH="$OPTARG" ;;
    j) MAX_JOBS="$OPTARG" ;;
    n) DRY_RUN=1 ;;
    h|*) usage ;;
  esac
done

command -v yq >/dev/null 2>&1 || { echo "ERROR: yq not found. Please install mikefarah/yq." >&2; exit 2; }
[ -f "$CONFIG" ] || { echo "ERROR: Config not found: $CONFIG" >&2; exit 2; }

yaml_get() {
  local path="$1"
  yq -r ".$path // \"\"" "$CONFIG"
}

log() { printf "\033[1;34m[run]\033[0m %s\n" "$*" >&2; }

DEFAULT_OUTPUT_DIR="$(yaml_get 'defaults.run.output_dir')"; : "${DEFAULT_OUTPUT_DIR:=output}"
DEFAULT_TIMEOUT="$(yaml_get 'defaults.run.timeout')"; : "${DEFAULT_TIMEOUT:=0}"
DEFAULT_INIT_TIMEOUT="$(yaml_get 'defaults.run.init_timeout')"; : "${DEFAULT_INIT_TIMEOUT:=120}"
DEFAULT_GLOB="$(yaml_get 'defaults.run.glob')"; : "${DEFAULT_GLOB:=*}"
DEFAULT_RECURSE="$(yaml_get 'defaults.run.recurse')"; : "${DEFAULT_RECURSE:=1}"

if [ -z "$AGENTS" ]; then
  AGENTS="$(yq -r '.agents | keys | join(",")' "$CONFIG")"
fi
IFS=',' read -r -a AGENT_LIST <<<"$AGENTS"

if [ "${MAX_JOBS:-0}" -le 0 ]; then
  MAX_JOBS="${#AGENT_LIST[@]}"
fi

export_env_for_agent() {
  local agent="$1"
  while IFS='=' read -r k v; do
    [ -z "$k" ] && continue
    if [[ "$v" =~ ^env:(.+)$ ]]; then
      src="${BASH_REMATCH[1]}"
      v="${!src:-}"
    fi
    export "$k=$v"
  done < <(yq -r '
    ((.defaults.env // {}) * (.agents."'$agent'".env // {}))
    | to_entries | .[] | "\(.key)=\(.value)"
  ' "$CONFIG")
}

expand_string() {
  local s="${1:-}"
  if command -v envsubst >/dev/null 2>&1; then
    printf '%s' "$s" | envsubst
  else
    [[ "$s" == *"\${MODEL"* ]] && : "${MODEL:=}"
    [[ "$s" == *"\${OPENAI_BASE_URL"* ]] && : "${OPENAI_BASE_URL:=}"
    [[ "$s" == *"\${ANTHROPIC_BASE_URL"* ]] && : "${ANTHROPIC_BASE_URL:=}"
    eval "echo \"$s\""
  fi
}

run_agent_init() {
  local agent="$1"
  local init_cmd="$2"
  local out_dir="$3"
  [ -z "${init_cmd:-}" ] && return 0
  local expanded_init
  expanded_init="$(expand_string "$init_cmd")"
  log "[$agent] Init: $expanded_init"
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  mkdir -p "$out_dir"
  local init_log="$out_dir/init.log"
  set +e
  if [ "$DEFAULT_INIT_TIMEOUT" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    ( set -o pipefail; timeout "$DEFAULT_INIT_TIMEOUT" bash -lc "$expanded_init" ) >"$init_log" 2>&1
    code=$?
  else
    ( set -o pipefail; bash -lc "$expanded_init" ) >"$init_log" 2>&1
    code=$?
  fi
  set -e
  if [ "$code" -ne 0 ]; then
    echo -e "\033[1;31m[run] $agent init failed: code $code (see $init_log)\033[0m" >&2
    return $code
  else
    echo -e "\033[1;32m[run] $agent init succeeded\033[0m" >&2
  fi
  return 0
}

run_one_file() {
  local agent="$1" cmd="$2" expanded_args="$3" out_dir="$4" file_path="$5"
  [ -f "$file_path" ] || return 0
  local INPUT_TEXT
  INPUT_TEXT="$(cat "$file_path")"
  export INPUT_TEXT
  local per_cmd="$cmd $expanded_args \"${INPUT_TEXT}\""

  local rel safe_rel log_path
  if [ -n "${TEST_PATH:-}" ] && [ -d "${TEST_PATH:-}" ]; then
    rel="${file_path#${TEST_PATH%/}/}"
  else
    rel="$(basename "$file_path")"
  fi
  safe_rel="${rel//\//__}"
  log_path="$out_dir/run_${safe_rel}.log"

  log "[$agent] File: $file_path"
  log "[$agent] Cmd:  $per_cmd"
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  set +e
  if [ "$DEFAULT_TIMEOUT" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    ( set -o pipefail; timeout "$DEFAULT_TIMEOUT" bash -lc "$per_cmd" ) 2>&1 | tee "$log_path"
    code="${PIPESTATUS[0]}"
  else
    ( set -o pipefail; bash -lc "$per_cmd" ) 2>&1 | tee "$log_path"
    code="${PIPESTATUS[0]}"
  fi
  set -e
  if [ "$code" -ne 0 ]; then
    echo -e "\033[1;31m[run] $agent <$rel> failed: $code\033[0m" >&2
  else
    echo -e "\033[1;32m[run] $agent <$rel> ok\033[0m" >&2
  fi
  return "$code"
}

one_agent_run() {
  local agent_trimmed="$1"
  [ -z "$agent_trimmed" ] && return 0

  local cmd args model init_cmd
  cmd="$(yaml_get "agents.$agent_trimmed.command")"
  args="$(yaml_get "agents.$agent_trimmed.args")"
  model="$(yaml_get "agents.$agent_trimmed.model")"
  init_cmd="$(yaml_get "agents.$agent_trimmed.init")"
  [ -z "$cmd" ] && { echo "ERROR: agents.$agent_trimmed.command missing" >&2; return 2; }

  export_env_for_agent "$agent_trimmed"

  if [[ "${args:-}" == *"\${MODEL"* ]] && [ -n "${model:-}" ]; then
    export MODEL="$model"
  fi

  local out_dir="$DEFAULT_OUTPUT_DIR/$agent_trimmed"
  mkdir -p "$out_dir"

  if ! run_agent_init "$agent_trimmed" "${init_cmd:-}" "$out_dir"; then
    return 1
  fi

  local expanded_args
  expanded_args="$(expand_string "${args:-}")"

  if [ -n "${TEST_PATH:-}" ] && [ -d "$TEST_PATH" ]; then
    local list
    local file_list_tmp
    file_list_tmp="$(mktemp)"
    if [ "$DEFAULT_RECURSE" -eq 1 ]; then
      find "$TEST_PATH" -type f -name "$DEFAULT_GLOB" -print0 | xargs -0 -I{} printf "%s\n" "{}" | LC_ALL=C sort > "$file_list_tmp"
    else
      shopt -s nullglob
      for f in "$TEST_PATH"/$DEFAULT_GLOB; do
        [ -f "$f" ] && printf "%s\n" "$f"
      done | LC_ALL=C sort > "$file_list_tmp"
      shopt -u nullglob
    fi

    while IFS= read -r path; do
      [ -n "$path" ] || continue
      run_one_file "$agent_trimmed" "$cmd" "$expanded_args" "$out_dir" "$path" || true
    done < "$file_list_tmp"
    rm -f "$file_list_tmp"
    return 0
  fi

  local final_cmd="$cmd $expanded_args"
  if [ -n "${TEST_PATH:-}" ] && [ -f "$TEST_PATH" ]; then
    local INPUT_TEXT
    INPUT_TEXT="$(cat "$TEST_PATH")"; export INPUT_TEXT
    final_cmd="$final_cmd \"${INPUT_TEXT}\""
  elif [ -n "${TEST_PATH:-}" ] && [ ! -e "$TEST_PATH" ]; then
    final_cmd="$final_cmd \"${TEST_PATH}\""
  fi

  log "[$agent_trimmed] Out: $out_dir"
  log "[$agent_trimmed] Cmd: $final_cmd"
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  set +e
  if [ "$DEFAULT_TIMEOUT" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
    ( set -o pipefail; timeout "$DEFAULT_TIMEOUT" bash -lc "$final_cmd" ) 2>&1 | tee "$out_dir/run.log"
    code="${PIPESTATUS[0]}"
  else
    ( set -o pipefail; bash -lc "$final_cmd" ) 2>&1 | tee "$out_dir/run.log"
    code="${PIPESTATUS[0]}"
  fi
  set -e
  if [ "$code" -ne 0 ]; then
    echo -e "\033[1;31m[run] $agent_trimmed failed: $code\033[0m" >&2
  else
    echo -e "\033[1;32m[run] $agent_trimmed ok\033[0m" >&2
  fi
  return "$code"
}

STATUS_DIR="$(mktemp -d)"
pids=()
names=()

run_bg_limited() {
  local name="$1"
  while [ "$(jobs -rp | wc -l)" -ge "$MAX_JOBS" ]; do sleep 0.2; done
  (
    code=0
    one_agent_run "$name" || code=$?
    echo "$code" > "$STATUS_DIR/$name.status"
  ) &
  pids+=( "$!" )
  names+=( "$name" )
}

for agent in "${AGENT_LIST[@]}"; do
  agent_trimmed="$(echo "$agent" | tr -d '[:space:]')"
  [ -z "$agent_trimmed" ] && continue
  run_bg_limited "$agent_trimmed"
done

overall=0
for i in "${!pids[@]}"; do
  wait "${pids[$i]}" || true
  name="${names[$i]}"
  code="$(cat "$STATUS_DIR/$name.status" 2>/dev/null || echo 1)"
  if [ "$code" -ne 0 ]; then
    overall=1
  end
done
rm -rf "$STATUS_DIR"
exit "$overall"
