# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo purpose

A research harness that runs **financial-agent skills** (trading, hedging, auditing, weekly-report generation, report evaluation) over historical or live market data. The same skill is reused for backtest replay and live runs — only the input dates and the backing DuckDB change.

## Common commands

Python is **3.12** (`.python-version`) and dependencies are managed by **uv** (`pyproject.toml` + `uv.lock`).

```bash
# Install / sync deps
uv sync

# Top-level CLI (typer-based, see main.py)
python main.py trading           -s AAPL --start 2026-01-02 --end 2026-04-30 -m anthropic:claude-sonnet-4-6
python main.py hedging                  --start 2026-01-02 --end 2026-04-30 -m anthropic:claude-sonnet-4-6
python main.py report-generation -s AAPL --start 2026-01-02 --end 2026-04-30 -m anthropic:claude-sonnet-4-6
python main.py auditing --ticker rrr --filing-name 10k --issue-time 20231231 \
    --concept-id us-gaap:AssetsCurrent --period "FY2023" -m anthropic:claude-sonnet-4-6

# Quick smoke test (trading only): first 3 trading days of the window
python main.py trading -s TSLA --start 2026-01-02 --end 2026-04-30 -m anthropic:claude-sonnet-4-6 --test
```

There are **no test, lint, or build commands** configured in this repo.

### Model spec (`-m / --model`)

Strings are routed inside `src/_common.py::_resolve_model`:

| Spec | Routes to |
|---|---|
| omitted | deepagents default (`claude-sonnet-4-6` via Anthropic) |
| `anthropic:claude-sonnet-4-6` | Anthropic API |
| `claude-...` (bare) | rewritten to `anthropic:claude-...` |
| `openai:gpt-5.4` | OpenAI API (`OPENAI_API_KEY`) |
| `openrouter:vendor/model` | OpenRouter base URL + `OPENROUTER_API_KEY` (built as a custom `ChatOpenAI`) |

A duplicated provider prefix (e.g. `openai:openai:gpt-5`) is auto-stripped.

`model_id()` sanitizes the spec into a filesystem-safe slug used in output filenames (`/` and any non `[A-Za-z0-9_-]` char → `_`, e.g. `openrouter:qwen/qwen3.5-397b-a17b` → `qwen_qwen3_5-397b-a17b`).

## Architecture

### The skill / pipeline / MCP triangle

Every task follows the same three-piece pattern:

1. **`skills/<task>/SKILL.md`** — the agent's only instructions for the task. Describes inputs, the MCP tool surface, the no-look-ahead rule, and how to call the helper script.
2. **`skills/<task>/scripts/mcp/<task>_mcp.py`** — a `fastmcp` server, started over stdio by the pipeline. Owns all read access to the offline DuckDB (and any other data root). Tool names use `snake_case`; arguments must be passed as native JSON, never as JSON-encoded strings (see hedging SKILL.md for the canonical examples).
3. **`skills/<task>/scripts/upsert_*.py`** — a small CLI the agent runs **via Bash** to write its result. The MCP server stays read-only; all file I/O lives in the upsert script (sanitize filename, load-or-create JSON, upsert by date, sort, recompute `start_date`/`end_date`, write).

The Python pipelines in `src/<task>_pipeline.py` glue this together:

- `_common.build_agent` builds a single `deepagents.create_deep_agent` with `LocalShellBackend(virtual_mode=True, inherit_env=True, root_dir=PROJECT_ROOT)`. **`LocalShellBackend` is required** (not `FilesystemBackend`) because the upsert step is a subprocess.
- The pipeline tells the agent which model to slug into the filename and which `--output-root` to write to. The agent then composes the upsert CLI call itself.
- Failures are caught per-item; permanent-vs-retryable errors are classified by `_is_retryable_error` (HTTP 4xx + `context_length_exceeded` are non-retryable; 429 / 5xx / connection errors retry with exponential backoff). Failures get appended to `{output_root}/errors/<task>_*_errors.json`.

### Concurrency model

- **Trading** and **report-generation** run concurrently across `(symbol, date)` items via an `asyncio.Semaphore` (default 3, override with `--concurrency`).
- **Hedging** runs **serially**, because day N reads the pair-file day N-1 wrote.
- **Auditing** and **report-evaluation** are one-shot per invocation (single item).

### Hedging fixed pair

`src/hedging_pipeline.py::_FIXED_PAIRS` maps a bare model name → `(LEFT, RIGHT)` and is the source of truth for which pair each model trades. The pipeline injects `left`/`right` into every per-day item, and `run_one` passes them through in the prompt (`The fixed pair for this run is: left=X, right=Y. Skip pair selection and use this pair directly.`). This is intentional: pair selection is a separate offline step, and the pair is locked across the run window.

If you add a new model, add it to `_FIXED_PAIRS` using the bare slug returned by `_pair_key()` (e.g. `openrouter:qwen/qwen3.5-9b` → key `qwen3.5-9b`).

### Date discipline

`main.py` resolves date windows using the NYSE calendar (`exchange_calendars.get_calendar("XNYS")`):

- `_trading_dates(start, end)` — every NYSE session in the inclusive window. Used for trading + hedging.
- `_weekly_endings(start, end)` — last NYSE session per ISO week (handles holiday-shortened weeks). Used for report-generation.

Inside the skill itself, the **no-look-ahead rule** is enforced *by the SKILL.md prompt*, not by the MCP server — the DB may contain rows after `TARGET_DATE`, and the agent is instructed never to query past it (with the single bootstrap exception of deriving `TARGET_DATE` when none is supplied).

### Data layout

- `data/env.duckdb` — default backing store for trading / hedging / report-generation MCP servers (`DEFAULT_DB` in `src/_common.py`).
- `data/Live/<YYYY-MM-DD>.duckdb` — per-day snapshots used for live experiments. Pass via `db_path=` if calling `run_pipeline` programmatically; the CLI in `main.py` does not yet expose a `--db-path` flag.
- `data/auditing/` — XBRL filings tree consumed by `auditing_mcp.py`.
- `live_trading/<SYMBOL>_trading.txt` — per-ticker date lists (tab-separated `index<TAB>YYYY-MM-DD`) defining the live-run window for each symbol.

### Output layout

- `results/trading/trading_{symbol}_{model_slug}.json`
- `results/hedging/hedging_{LEFT}_{RIGHT}_{model_slug}.json`
- `results/report_generation/...`, `results/auditing/...`, `results/report_evaluation/...`
- `results/<task>/errors/<task>_..._errors.json` — append-only error log per (task, symbol, model) tuple

`results/` and `io/` are **gitignored**. The `.env` file is gitignored and holds `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `LOGFIRE_TOKEN`.

### Observability

`main.py` initializes `logfire` with service name `financial-agents` and instruments both `anthropic` and `mcp`. Spans wrap every agent invocation, MCP tool load, and pipeline run. `LOGFIRE_TOKEN` in `.env` ships traces to the configured project.

## Adding a new skill

1. Create `skills/<task>/SKILL.md` (frontmatter `name:` + `description:`, then prose).
2. Add `skills/<task>/scripts/mcp/<task>_mcp.py` (fastmcp stdio server) and `scripts/upsert_*.py` (CLI writer).
3. Add `src/<task>_pipeline.py` modeled on the existing pipelines — must define `SKILL_DIR`, `MCP_SCRIPT`, `DEFAULT_OUTPUT_ROOT`, `_mcp_servers`, `run_one`, `run_pipeline`.
4. Wire a typer command in `main.py` that calls `asyncio.run(run_pipeline(...))`.
5. The agent reaches the skill via `.claude/skills` (a symlink to `../skills`), so no extra registration is needed.