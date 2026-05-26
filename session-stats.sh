#!/usr/bin/env bash
#
# session-stats.sh — Extract full statistics for an opencode session tree
# (parent + all subagent child sessions) by querying the local SQLite DB.
#
# Usage:
#   ./session-stats.sh <session-id>          # formatted table output
#   ./session-stats.sh --json <session-id>   # JSON output
#   ./session-stats.sh --list                 # list recent root sessions
#   ./session-stats.sh --latest              # stats for most recent root session
#
# Requirements: sqlite3 (with JSON1 extension — standard since SQLite 3.38+)

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────

OUTPUT_FORMAT="table"
SESSION_ID=""
LIST_MODE=false
LATEST_MODE=false

# ─── Argument parsing ─────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [SESSION_ID]

Extract token usage, cost, model breakdown, tool usage, and timing
for an opencode session and all its subagent child sessions.

Options:
  --json         Output as JSON instead of formatted table
  --list         List the 20 most recent root sessions
  --latest       Show stats for the most recent root session
  --db PATH      Override the database path
  -h, --help     Show this help

Arguments:
  SESSION_ID     The root session ID (starts with "ses_")

Examples:
  $(basename "$0") ses_01JXY...
  $(basename "$0") --json ses_01JXY...
  $(basename "$0") --list
  $(basename "$0") --latest --json
EOF
  exit 0
}

DB_PATH_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      OUTPUT_FORMAT="json"
      shift
      ;;
    --list)
      LIST_MODE=true
      shift
      ;;
    --latest)
      LATEST_MODE=true
      shift
      ;;
    --db)
      DB_PATH_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    -*)
      echo "Error: Unknown option: $1" >&2
      exit 1
      ;;
    *)
      SESSION_ID="$1"
      shift
      ;;
  esac
done

# ─── Discover database path ──────────────────────────────────────────────────

discover_db() {
  if [[ -n "$DB_PATH_OVERRIDE" ]]; then
    echo "$DB_PATH_OVERRIDE"
    return
  fi

  # Try opencode CLI first
  if command -v opencode &>/dev/null; then
    local path
    path=$(opencode db path 2>/dev/null || true)
    if [[ -n "$path" && -f "$path" ]]; then
      echo "$path"
      return
    fi
  fi

  # Fallback: standard XDG path
  local xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}"
  local candidates=(
    "$xdg_data/opencode/opencode.db"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done

  echo "Error: Could not find opencode database." >&2
  echo "Try: opencode db path" >&2
  echo "Or pass --db /path/to/opencode.db" >&2
  exit 1
}

DB_PATH=$(discover_db)

# Verify sqlite3 is available
if ! command -v sqlite3 &>/dev/null; then
  echo "Error: sqlite3 is required but not found in PATH." >&2
  exit 1
fi

sql() {
  sqlite3 -json "$DB_PATH" "$1"
}

sql_raw() {
  sqlite3 "$DB_PATH" "$1"
}

# ─── List mode ────────────────────────────────────────────────────────────────

if [[ "$LIST_MODE" == true ]]; then
  QUERY="
    SELECT id, title,
           datetime(time_created/1000, 'unixepoch', 'localtime') AS created,
           datetime(time_updated/1000, 'unixepoch', 'localtime') AS updated,
           ROUND(cost, 4) AS cost
    FROM session
    WHERE parent_id IS NULL
    ORDER BY time_updated DESC
    LIMIT 20;
  "

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    sql "$QUERY"
  else
    echo "Recent root sessions:"
    echo "─────────────────────────────────────────────────────────────────────────────────"
    printf "%-28s %-40s %s\n" "ID" "TITLE" "UPDATED"
    echo "─────────────────────────────────────────────────────────────────────────────────"
    sqlite3 -separator '|' "$DB_PATH" "$QUERY" | while IFS='|' read -r id title created updated cost; do
      printf "%-28s %-40.40s %s\n" "$id" "$title" "$updated"
    done
  fi
  exit 0
fi

# ─── Latest mode ──────────────────────────────────────────────────────────────

if [[ "$LATEST_MODE" == true && -z "$SESSION_ID" ]]; then
  SESSION_ID=$(sql_raw "SELECT id FROM session WHERE parent_id IS NULL ORDER BY time_updated DESC LIMIT 1;")
  if [[ -z "$SESSION_ID" ]]; then
    echo "Error: No sessions found in database." >&2
    exit 1
  fi
fi

# ─── Validate session ID ─────────────────────────────────────────────────────

if [[ -z "$SESSION_ID" ]]; then
  echo "Error: Session ID required. Use --list to find one, or --latest." >&2
  echo "Run with -h for help." >&2
  exit 1
fi

# Verify session exists
EXISTS=$(sql_raw "SELECT COUNT(*) FROM session WHERE id = '$SESSION_ID';")
if [[ "$EXISTS" == "0" ]]; then
  echo "Error: Session not found: $SESSION_ID" >&2
  exit 1
fi

# ─── Queries ──────────────────────────────────────────────────────────────────

# 1. Overview: session tree totals
OVERVIEW_QUERY="
WITH RECURSIVE tree AS (
  SELECT id, parent_id, cost, tokens_input, tokens_output, tokens_reasoning,
         tokens_cache_read, tokens_cache_write, time_created, time_updated, title, agent
  FROM session
  WHERE id = '$SESSION_ID'
  UNION ALL
  SELECT s.id, s.parent_id, s.cost, s.tokens_input, s.tokens_output,
         s.tokens_reasoning, s.tokens_cache_read, s.tokens_cache_write,
         s.time_created, s.time_updated, s.title, s.agent
  FROM session s
  JOIN tree t ON s.parent_id = t.id
)
SELECT
  (SELECT title FROM tree LIMIT 1) AS session_title,
  (SELECT agent FROM tree LIMIT 1) AS root_agent,
  (SELECT COUNT(*) FROM tree) AS sessions_in_tree,
  (SELECT COUNT(*) FROM tree WHERE parent_id IS NOT NULL) AS subagent_sessions,
  (SELECT COUNT(*) FROM message m JOIN tree t ON m.session_id = t.id) AS total_messages,
  ROUND((SELECT COALESCE(SUM(cost), 0) FROM tree), 6) AS total_cost,
  (SELECT COALESCE(SUM(tokens_input), 0) FROM tree) AS input_tokens,
  (SELECT COALESCE(SUM(tokens_output), 0) FROM tree) AS output_tokens,
  (SELECT COALESCE(SUM(tokens_reasoning), 0) FROM tree) AS reasoning_tokens,
  (SELECT COALESCE(SUM(tokens_cache_read), 0) FROM tree) AS cache_read_tokens,
  (SELECT COALESCE(SUM(tokens_cache_write), 0) FROM tree) AS cache_write_tokens,
  (SELECT COALESCE(SUM(tokens_input + tokens_output + tokens_reasoning + tokens_cache_read + tokens_cache_write), 0) FROM tree) AS total_tokens,
  (SELECT MIN(time_created) FROM tree) AS started_ms,
  (SELECT MAX(time_updated) FROM tree) AS ended_ms,
  ROUND((SELECT (MAX(time_updated) - MIN(time_created)) / 1000.0 FROM tree), 1) AS wall_seconds;
"

# 2. Model/agent breakdown
MODEL_QUERY="
WITH RECURSIVE tree(id) AS (
  SELECT id FROM session WHERE id = '$SESSION_ID'
  UNION ALL
  SELECT s.id FROM session s JOIN tree t ON s.parent_id = t.id
)
SELECT
  COALESCE(json_extract(m.data, '\$.agent'), 'unknown') AS agent,
  COALESCE(json_extract(m.data, '\$.providerID'), '?') || '/' || COALESCE(json_extract(m.data, '\$.modelID'), '?') AS model,
  COUNT(*) AS messages,
  ROUND(SUM(COALESCE(json_extract(m.data, '\$.cost'), 0)), 6) AS cost,
  SUM(COALESCE(json_extract(m.data, '\$.tokens.input'), 0)) AS input_tokens,
  SUM(COALESCE(json_extract(m.data, '\$.tokens.output'), 0)) AS output_tokens,
  SUM(COALESCE(json_extract(m.data, '\$.tokens.reasoning'), 0)) AS reasoning_tokens,
  SUM(COALESCE(json_extract(m.data, '\$.tokens.cache.read'), 0)) AS cache_read_tokens,
  SUM(COALESCE(json_extract(m.data, '\$.tokens.cache.write'), 0)) AS cache_write_tokens
FROM message m
JOIN tree t ON m.session_id = t.id
WHERE json_extract(m.data, '\$.role') = 'assistant'
GROUP BY agent, model
ORDER BY cost DESC;
"

# 3. Tool usage
TOOL_QUERY="
WITH RECURSIVE tree(id) AS (
  SELECT id FROM session WHERE id = '$SESSION_ID'
  UNION ALL
  SELECT s.id FROM session s JOIN tree t ON s.parent_id = t.id
)
SELECT
  json_extract(p.data, '\$.tool') AS tool_name,
  COUNT(*) AS call_count
FROM part p
JOIN tree t ON p.session_id = t.id
WHERE json_extract(p.data, '\$.type') = 'tool'
  AND json_extract(p.data, '\$.tool') IS NOT NULL
GROUP BY tool_name
ORDER BY call_count DESC;
"

# 4. Child session details
CHILDREN_QUERY="
WITH RECURSIVE tree AS (
  SELECT id, parent_id, title, agent, cost, tokens_input, tokens_output,
         tokens_reasoning, tokens_cache_read, tokens_cache_write,
         time_created, time_updated, 0 AS depth
  FROM session
  WHERE id = '$SESSION_ID'
  UNION ALL
  SELECT s.id, s.parent_id, s.title, s.agent, s.cost, s.tokens_input, s.tokens_output,
         s.tokens_reasoning, s.tokens_cache_read, s.tokens_cache_write,
         s.time_created, s.time_updated, t.depth + 1
  FROM session s
  JOIN tree t ON s.parent_id = t.id
)
SELECT id, depth, agent, ROUND(cost, 6) AS cost,
       tokens_input + tokens_output + tokens_reasoning + tokens_cache_read + tokens_cache_write AS total_tokens,
       SUBSTR(title, 1, 60) AS title
FROM tree
ORDER BY time_created ASC;
"

# ─── Output ───────────────────────────────────────────────────────────────────

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  # Combine all queries into a single JSON object
  OVERVIEW=$(sql "$OVERVIEW_QUERY")
  MODELS=$(sql "$MODEL_QUERY")
  TOOLS=$(sql "$TOOL_QUERY")
  CHILDREN=$(sql "$CHILDREN_QUERY")

  # Use a here-doc with jq if available, else raw concat
  if command -v jq &>/dev/null; then
    jq -n \
      --argjson overview "$OVERVIEW" \
      --argjson models "$MODELS" \
      --argjson tools "$TOOLS" \
      --argjson children "$CHILDREN" \
      '{
        session_id: "'"$SESSION_ID"'",
        overview: $overview[0],
        models: $models,
        tools: $tools,
        children: $children
      }'
  else
    echo "{"
    echo "  \"session_id\": \"$SESSION_ID\","
    echo "  \"overview\": $(echo "$OVERVIEW" | sed 's/^\[//;s/\]$//'),"
    echo "  \"models\": $MODELS,"
    echo "  \"tools\": $TOOLS,"
    echo "  \"children\": $CHILDREN"
    echo "}"
  fi
  exit 0
fi

# ─── Table output ─────────────────────────────────────────────────────────────

format_number() {
  local num=$1
  if [[ -z "$num" || "$num" == "null" ]]; then
    echo "0"
    return
  fi
  # Use printf for thousand separators if locale supports it
  printf "%'d" "$num" 2>/dev/null || echo "$num"
}

format_cost() {
  local cost=$1
  if [[ -z "$cost" || "$cost" == "null" ]]; then
    echo "\$0.000000"
    return
  fi
  echo "\$$cost"
}

format_duration() {
  local seconds=$1
  if [[ -z "$seconds" || "$seconds" == "null" || "$seconds" == "0" ]]; then
    echo "N/A"
    return
  fi
  local int_seconds=${seconds%.*}
  if [[ $int_seconds -ge 3600 ]]; then
    printf "%dh %dm %ds" $((int_seconds/3600)) $((int_seconds%3600/60)) $((int_seconds%60))
  elif [[ $int_seconds -ge 60 ]]; then
    printf "%dm %ds" $((int_seconds/60)) $((int_seconds%60))
  else
    printf "%ss" "$seconds"
  fi
}

# Read overview
read_overview() {
  sqlite3 -separator '|' "$DB_PATH" "$OVERVIEW_QUERY"
}

IFS='|' read -r title root_agent sessions_in_tree subagent_sessions total_messages \
  total_cost input_tokens output_tokens reasoning_tokens cache_read cache_write \
  total_tokens started_ms ended_ms wall_seconds < <(read_overview)

W=60

echo ""
echo "┌$(printf '─%.0s' $(seq 1 $W))┐"
echo "│$(printf ' %.0s' $(seq 1 $(( (W - 16) / 2 ))))SESSION OVERVIEW$(printf ' %.0s' $(seq 1 $(( (W - 16 + 1) / 2 ))))│"
echo "├$(printf '─%.0s' $(seq 1 $W))┤"
printf "│ %-20s %$(( W - 23 ))s │\n" "Session ID" "$SESSION_ID"
printf "│ %-20s %$(( W - 23 ))s │\n" "Title" "${title:0:$((W-24))}"
printf "│ %-20s %$(( W - 23 ))s │\n" "Root Agent" "${root_agent:-N/A}"
printf "│ %-20s %$(( W - 23 ))s │\n" "Sessions (tree)" "$sessions_in_tree (${subagent_sessions} subagents)"
printf "│ %-20s %$(( W - 23 ))s │\n" "Total Messages" "$(format_number "$total_messages")"
printf "│ %-20s %$(( W - 23 ))s │\n" "Wall Time" "$(format_duration "$wall_seconds")"
echo "└$(printf '─%.0s' $(seq 1 $W))┘"
echo ""

echo "┌$(printf '─%.0s' $(seq 1 $W))┐"
echo "│$(printf ' %.0s' $(seq 1 $(( (W - 14) / 2 ))))COST & TOKENS$(printf ' %.0s' $(seq 1 $(( (W - 14 + 1) / 2 ))))│"
echo "├$(printf '─%.0s' $(seq 1 $W))┤"
printf "│ %-20s %$(( W - 23 ))s │\n" "Total Cost" "$(format_cost "$total_cost")"
printf "│ %-20s %$(( W - 23 ))s │\n" "Total Tokens" "$(format_number "$total_tokens")"
printf "│ %-20s %$(( W - 23 ))s │\n" "  Input" "$(format_number "$input_tokens")"
printf "│ %-20s %$(( W - 23 ))s │\n" "  Output" "$(format_number "$output_tokens")"
printf "│ %-20s %$(( W - 23 ))s │\n" "  Reasoning" "$(format_number "$reasoning_tokens")"
printf "│ %-20s %$(( W - 23 ))s │\n" "  Cache Read" "$(format_number "$cache_read")"
printf "│ %-20s %$(( W - 23 ))s │\n" "  Cache Write" "$(format_number "$cache_write")"
echo "└$(printf '─%.0s' $(seq 1 $W))┘"
echo ""

# Model breakdown
echo "┌$(printf '─%.0s' $(seq 1 $W))┐"
echo "│$(printf ' %.0s' $(seq 1 $(( (W - 15) / 2 ))))MODEL BREAKDOWN$(printf ' %.0s' $(seq 1 $(( (W - 15 + 1) / 2 ))))│"
echo "├$(printf '─%.0s' $(seq 1 $W))┤"

sqlite3 -separator '|' "$DB_PATH" "$MODEL_QUERY" | while IFS='|' read -r agent model messages cost in_tok out_tok reason_tok cr_tok cw_tok; do
  printf "│ %-58s │\n" "@${agent} — ${model}"
  printf "│   %-18s %$(( W - 25 ))s │\n" "Messages" "$messages"
  printf "│   %-18s %$(( W - 25 ))s │\n" "Cost" "$(format_cost "$cost")"
  printf "│   %-18s %$(( W - 25 ))s │\n" "Tokens (in/out)" "$(format_number "$in_tok") / $(format_number "$out_tok")"
  echo "│$(printf ' %.0s' $(seq 1 $W))│"
done

echo "└$(printf '─%.0s' $(seq 1 $W))┘"
echo ""

# Tool usage
TOOL_RESULTS=$(sqlite3 -separator '|' "$DB_PATH" "$TOOL_QUERY")
if [[ -n "$TOOL_RESULTS" ]]; then
  echo "┌$(printf '─%.0s' $(seq 1 $W))┐"
  echo "│$(printf ' %.0s' $(seq 1 $(( (W - 10) / 2 ))))TOOL USAGE$(printf ' %.0s' $(seq 1 $(( (W - 10 + 1) / 2 ))))│"
  echo "├$(printf '─%.0s' $(seq 1 $W))┤"

  MAX_COUNT=$(echo "$TOOL_RESULTS" | head -1 | cut -d'|' -f2)

  echo "$TOOL_RESULTS" | while IFS='|' read -r tool count; do
    local_bar_len=$(( count * 20 / (MAX_COUNT > 0 ? MAX_COUNT : 1) ))
    [[ $local_bar_len -lt 1 ]] && local_bar_len=1
    bar=$(printf '█%.0s' $(seq 1 $local_bar_len))
    printf "│ %-20.20s %-20s %5s │\n" "$tool" "$bar" "$count"
  done

  echo "└$(printf '─%.0s' $(seq 1 $W))┘"
  echo ""
fi

# Child sessions
if [[ "$subagent_sessions" -gt 0 ]]; then
  echo "┌$(printf '─%.0s' $(seq 1 $W))┐"
  echo "│$(printf ' %.0s' $(seq 1 $(( (W - 12) / 2 ))))SESSION TREE$(printf ' %.0s' $(seq 1 $(( (W - 12 + 1) / 2 ))))│"
  echo "├$(printf '─%.0s' $(seq 1 $W))┤"

  sqlite3 -separator '|' "$DB_PATH" "$CHILDREN_QUERY" | while IFS='|' read -r sid depth agent cost tokens stitle; do
    indent=$(printf '%*s' $((depth * 2)) '')
    if [[ "$depth" == "0" ]]; then
      prefix="*"
    else
      prefix="└"
    fi
    line="${indent}${prefix} @${agent:-?} ($(format_number "$tokens") tok, \$$cost)"
    printf "│ %-58.58s │\n" "$line"
  done

  echo "└$(printf '─%.0s' $(seq 1 $W))┘"
  echo ""
fi
