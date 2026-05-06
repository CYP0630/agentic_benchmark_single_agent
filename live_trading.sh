#!/usr/bin/env bash
# hermes_live_trading.sh
#
# Live trading experiment driver. For each (model, ticker, date) triple:
#   1. resolve the per-day DB at data/Live/<DATE>.duckdb
#   2. invoke `python main.py trading` for that single day with --db-path
#      pointing at that DB and --output-root under live_results/trading
#   3. results are upserted into
#         live_results/trading/trading_<TICKER>_<MODEL_SLUG>.json
#
# Resume-safe: dates already recorded in the per-(ticker, model) output JSON
# are skipped, so re-running the script after a crash only fills in gaps.
#
# Per-ticker date ranges come from live_trading/<TICKER>_trading.txt
# (tab-separated "<index>\t<YYYY-MM-DD>"). NYSE non-trading days are filtered
# out before invoking main.py to avoid paying agent cold-start cost on no-ops.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_ROOT"

LIVE_DB_DIR="${PROJECT_ROOT}/data/Live"
LIVE_DATES_DIR="${PROJECT_ROOT}/live_trading"
OUTPUT_ROOT="${PROJECT_ROOT}/live_results/trading"

mkdir -p "$OUTPUT_ROOT"

# Prefer the project venv if present; fall back to whatever `python` is on PATH.
if [[ -x "${PROJECT_ROOT}/.venv/bin/python" ]]; then
  PY="${PROJECT_ROOT}/.venv/bin/python"
else
  PY="python"
fi

# Format: "<model spec>|<filename slug used by upsert_decision.py>"
# The slug must equal model_id(spec).lower() (see src/_common.py::model_id);
# it's duplicated here so bash can compute the resume-skip output path.
MODELS=(
  "anthropic:claude-sonnet-4-6|claude-sonnet-4-6"
  "openai:gpt-5.4|gpt-5_4"
  "openrouter:qwen/qwen3.5-397b-a17b|qwen_qwen3_5-397b-a17b"
  "openrouter:qwen/qwen3.5-27b|qwen_qwen3_5-27b"
)

TICKERS=(AAPL MSFT NVDA TSLA)

# Filter a list of YYYY-MM-DD dates down to NYSE trading sessions only.
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
for d in dates_in:
    if d in sessions:
        print(d)
PY
}

run_count=0
skip_count=0

for entry in "${MODELS[@]}"; do
  model_spec="${entry%|*}"
  model_slug="${entry##*|}"

  for ticker in "${TICKERS[@]}"; do
    date_file="${LIVE_DATES_DIR}/${ticker}_trading.txt"
    out_file="${OUTPUT_ROOT}/trading_${ticker}_${model_slug}.json"

    if [[ ! -f "$date_file" ]]; then
      echo "[skip] missing date list: $date_file" >&2
      continue
    fi

    # Pull the YYYY-MM-DD column from "<index>\t<YYYY-MM-DD>" lines, skipping
    # blank/incomplete rows.
    raw_dates=$(awk -F'\t' 'NF>=2 && $2 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ {print $2}' "$date_file")
    if [[ -z "$raw_dates" ]]; then
      echo "[skip] empty date list: $date_file" >&2
      continue
    fi

    trading_dates=$(nyse_filter $raw_dates)

    for d in $trading_dates; do
      db_path="${LIVE_DB_DIR}/${d}.duckdb"
      if [[ ! -f "$db_path" ]]; then
        echo "[skip] missing DB: $db_path" >&2
        skip_count=$((skip_count + 1))
        continue
      fi

      # Resume: if this date is already present in the output JSON, leave it.
      if [[ -f "$out_file" ]] && grep -q "\"date\": \"$d\"" "$out_file"; then
        echo "[skip] already recorded: $ticker $d $model_spec"
        skip_count=$((skip_count + 1))
        continue
      fi

      echo "[run] trading $ticker $d $model_spec"
      "$PY" main.py trading \
        --symbol "$ticker" \
        --start "$d" --end "$d" \
        --model "$model_spec" \
        --db-path "$db_path" \
        --output-root "$OUTPUT_ROOT" \
        --concurrency 1
      run_count=$((run_count + 1))
    done
  done
done

echo "✓ hermes_live_trading.sh complete — ran=$run_count skipped=$skip_count"