#!/usr/bin/env bash
# hermes_live_hedging.sh
#
# Live hedging experiment driver. For each model, iterate every NYSE trading
# day for which data/Live/<DATE>.duckdb exists, in order, calling
# `python main.py hedging` once per (model, date) with --db-path pointing at
# that day's DB and --output-root under live_results/hedging.
#
# The pair per model is the FIXED pair declared in
# src/hedging_pipeline.py::_FIXED_PAIRS. The pipeline injects (left, right)
# into every item, and on day-1 (no output file yet) the agent writes the
# first record with that pair without doing pair selection. On every later
# day, hedging_pipeline detects the existing output file and forces
# is_first_day=False, so the agent reads the same pair and only emits a
# daily action — the pair never changes for that model across the run.
#
# Per-model dates run STRICTLY in order (day N reads the pair file day N-1
# wrote). Resume-safe: dates already recorded are skipped.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_ROOT"

LIVE_DB_DIR="${PROJECT_ROOT}/data/Live"
OUTPUT_ROOT="${PROJECT_ROOT}/live_results/hedging"

mkdir -p "$OUTPUT_ROOT"

if [[ -x "${PROJECT_ROOT}/.venv/bin/python" ]]; then
  PY="${PROJECT_ROOT}/.venv/bin/python"
else
  PY="python"
fi

# Format: "<model spec>|<filename slug>|<LEFT>|<RIGHT>"
# LEFT/RIGHT MUST match src/hedging_pipeline.py::_FIXED_PAIRS for that model;
# they are duplicated here only so this script can compute the output filename
# for the resume-skip check. If you change a pair, change it in BOTH places.
MODELS=(
  "anthropic:claude-sonnet-4-6|claude-sonnet-4-6|GOOGL|MSFT"
  "openai:gpt-5.4|gpt-5_4|MSFT|TSLA"
  "openrouter:qwen/qwen3.5-397b-a17b|qwen_qwen3_5-397b-a17b|AAPL|MSFT"
  "openrouter:qwen/qwen3.5-27b|qwen_qwen3_5-27b|GOOGL|MSFT"
)

# Filter a list of YYYY-MM-DD dates down to NYSE trading sessions only,
# emitting them in chronological order (critical: hedging is stateful).
nyse_filter() {
  "$PY" - "$@" <<'PY'
import sys
import exchange_calendars as xcals

dates_in = sys.argv[1:]
if not dates_in:
    sys.exit(0)
nyse = xcals.get_calendar("XNYS")
sessions = {
    s.strftime("%Y-%m-%d")
    for s in nyse.sessions_in_range(min(dates_in), max(dates_in))
}
for d in sorted(dates_in):
    if d in sessions:
        print(d)
PY
}

# Discover available dates from the per-day DB filenames.
raw_dates=$(
  ls "${LIVE_DB_DIR}"/*.duckdb 2>/dev/null \
    | sed -E 's|.*/([0-9]{4}-[0-9]{2}-[0-9]{2})\.duckdb$|\1|'
)
if [[ -z "$raw_dates" ]]; then
  echo "[error] no DBs found in $LIVE_DB_DIR" >&2
  exit 1
fi
TRADING_DATES=$(nyse_filter $raw_dates)

run_count=0
skip_count=0

for entry in "${MODELS[@]}"; do
  IFS='|' read -r model_spec model_slug left right <<< "$entry"
  out_file="${OUTPUT_ROOT}/hedging_${left}_${right}_${model_slug}.json"

  echo "=== model=$model_spec  pair=$left/$right ==="

  for d in $TRADING_DATES; do
    db_path="${LIVE_DB_DIR}/${d}.duckdb"
    if [[ ! -f "$db_path" ]]; then
      echo "[skip] missing DB: $db_path" >&2
      skip_count=$((skip_count + 1))
      continue
    fi

    if [[ -f "$out_file" ]] && grep -q "\"date\": \"$d\"" "$out_file"; then
      echo "[skip] already recorded: $d ($left/$right) $model_spec"
      skip_count=$((skip_count + 1))
      continue
    fi

    echo "[run] hedging $d ($left/$right) $model_spec"
    "$PY" main.py hedging \
      --start "$d" --end "$d" \
      --model "$model_spec" \
      --db-path "$db_path" \
      --output-root "$OUTPUT_ROOT"
    run_count=$((run_count + 1))
  done
done

echo "✓ hermes_live_hedging.sh complete — ran=$run_count skipped=$skip_count"