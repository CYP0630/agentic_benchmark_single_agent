# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A trading-agent benchmark harness. `main.py` is a Typer CLI that drives an LLM agent (via the `deepagents` library) across a range of NYSE trading sessions, one invocation per `(symbol, date)`. The agent reads offline market data from a DuckDB file through an MCP server and upserts one decision record per day into a per-run JSON file.

## Commands

Dependencies are managed with `uv` (Python >=3.12, see `pyproject.toml`, `uv.lock`).

```bash
# Install / sync deps
uv sync

# Run the agent over a date range (NYSE sessions only)
uv run python main.py single-agent --symbol TSLA --start 2025-04-07 --end 2025-04-11

# First 3 trading days only (smoke test)
uv run python main.py single-agent -s TSLA --start 2025-04-07 --end 2025-05-30 --test

# Concurrency (default 3)
uv run python main.py single-agent -s TSLA --start ... --end ... -c 5
```

There are no tests, lint config, or build step. Observability goes to Logfire (`service_name="trading-agent"`, Anthropic + MCP auto-instrumented in `main.py`).

### Secrets

`.env` is gitignored and holds `ANTHROPIC_API_KEY` and `LOGFIRE_TOKEN`, loaded via `python-dotenv` at startup.

## Architecture

### Runtime pipeline (`main.py` → `src/pipeline.py`)

1. `main.py` expands `--start`/`--end` into NYSE sessions via `exchange_calendars` (`XNYS`), then builds one input dict per date: `{"prompt": "trade {symbol} on {date}", "symbol", "date"}`.
2. `src/pipeline.py::build_agent()` spins up an `MultiServerMCPClient` that launches `skills/trading-only/trading/scripts/mcp/trading_mcp.py` as a stdio subprocess, pointed at `data/research.duckdb`. The MCP tools are injected into a `deepagents.create_deep_agent` call.
3. The agent is built **once**, then `asyncio.gather` fans out `run_one(...)` calls under an `asyncio.Semaphore(concurrency)`. Each day gets a unique `thread_id = "{symbol}-{date}"` so the agent's state checkpointer keeps their histories separate.
4. The model is hardcoded: `anthropic:claude-sonnet-4-6`.
5. The agent's filesystem is scoped by `FilesystemBackend(root_dir=PROJECT_ROOT, virtual_mode=True)` and skills are mounted via `skills=["/skills/trading-only/"]` — only the trading skill is wired into this pipeline.

### MCP data layer (`skills/trading-only/trading/scripts/mcp/trading_mcp.py`)

A FastMCP server exposing DuckDB-backed tools over stdio. Three tables (see `scripts/mcp/schema.sql`): `prices` (OHLCV + `adj_close` — the canonical trading price), `news`, `filings` (with `mda_content`, `risk_content`). The server opens a **short-lived read-only** connection per tool call so an external populator can write concurrently.

Tool design deliberately splits list/get pairs (`list_news`/`get_news_by_id`, `list_filings`/`get_filing_section`) — returning all article bodies or all filing sections in one call can exceed the model's context limit. The skill prompts steer the agent to the compact-metadata tools first.

`is_trading_day(symbol, target_date)` is the single entry point for "is this a market day?" — it replaces weekday math, missing-row probing, and `get_latest_date` with one call that returns a `reason ∈ {'trading_day', 'weekend', 'holiday', 'not_loaded'}`.

### Skills (`skills/**/SKILL.md`)

Each subdirectory is a self-contained agent task described by a single `SKILL.md` with YAML frontmatter (`name`, `description`) and an extensive body of operating instructions. Only `trading-only/trading/` is currently wired into the pipeline; the others (`auditing/`, `pair_trading/`, `report_evaluation/`, `report_generation/`) are standalone skill specs covering adjacent tasks and are loaded when the corresponding pipeline wires them in via the `skills=[...]` argument.

### Per-day output — upsert-only

The trading skill writes via `skills/trading-only/trading/scripts/upsert_decision.py` (invoked by the agent through Bash), **never** by writing JSON inline. The script owns: filename sanitization, load-or-create, upsert by `target_date`, sort by date, recompute `start_date`/`end_date`, write. Re-running the same date overwrites that day's record.

Output path: `results/trading/trading_{SYMBOL}_{model}.json` (sanitization: non-`[A-Za-z0-9_-]` → `_`, model lowercased).

### No-look-ahead discipline

Every MCP data tool's `date_end` (and any specific `date` argument) must be `<= TARGET_DATE`. The DuckDB may contain data past `TARGET_DATE` (e.g. during historical replay), so the guardrail is enforced in prompts, not in code. The `get_indicator` tool auto-fetches warmup history *before* `date_start` internally so the agent doesn't need to think about lookback windows.

### Why helper CLIs instead of inline Python

The skill explicitly forbids the agent from writing inline Python via Bash heredocs for date math or JSON I/O. `scripts/date_offset.py` and `scripts/upsert_decision.py` exist so the agent has one canonical way to do each operation — this keeps tool calls short, deterministic, and cheap in tokens.

## Layout notes

- `data/` and `results/` are gitignored — `data/research.duckdb` is populated outside this repo; `results/` accumulates per-run JSON.
- `src/__init__.py` is empty on purpose; `src/pipeline.py` is the only module.
- Non-trading skills (`auditing`, `report_generation`, `report_evaluation`, `pair_trading`) reference paths like `data/trading/*.parquet`, `data/auditing/XBRL/*` that are not part of this repo's harness — they come from the broader `financial_agentic_benchmark` dataset.