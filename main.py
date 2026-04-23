import asyncio
from datetime import date

import exchange_calendars as xcals
import logfire
import typer
from dotenv import load_dotenv

from src.pipeline import run_pipeline

load_dotenv(".env")

logfire.configure(service_name="trading-agent")
logfire.instrument_anthropic()
logfire.instrument_mcp()

app = typer.Typer()

_NYSE = xcals.get_calendar("XNYS")


@app.callback()
def call_back():
    pass


def _trading_dates(start: date, end: date) -> list[str]:
    sessions = _NYSE.sessions_in_range(start.isoformat(), end.isoformat())
    return [s.strftime("%Y-%m-%d") for s in sessions]


@app.command("single-agent")
def single_agent(
    symbol: str = typer.Option(..., "--symbol", "-s", help="Stock symbol, e.g. AAPL"),
    start: str = typer.Option(..., "--start", help="Start date YYYY-MM-DD (inclusive)"),
    end: str = typer.Option(..., "--end", help="End date YYYY-MM-DD (inclusive)"),
    concurrency: int = typer.Option(3, "--concurrency", "-c", help="Max concurrent agent calls"),
    test: bool = typer.Option(False, "--test", help="Test mode: only run the first 3 trading days"),
):
    start_d = date.fromisoformat(start)
    end_d = date.fromisoformat(end)
    if end_d < start_d:
        raise typer.BadParameter("--end must be >= --start")

    dates = _trading_dates(start_d, end_d)
    if test:
        dates = dates[:3]

    inputs = [
        {"prompt": f"trade {symbol} on {d}", "symbol": symbol, "date": d}
        for d in dates
    ]
    asyncio.run(run_pipeline(inputs, concurrency=concurrency))


if __name__ == "__main__":
    app()
