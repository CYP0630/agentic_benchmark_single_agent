import asyncio
from pathlib import Path
from typing import Any, Iterable

import logfire
from deepagents import create_deep_agent
from deepagents.backends import FilesystemBackend
from langchain_mcp_adapters.client import MultiServerMCPClient

PROJECT_ROOT = Path(__file__).resolve().parent.parent
TRADING_MCP = PROJECT_ROOT / "skills" / "trading-only" / "trading" / "scripts" / "mcp" / "trading_mcp.py"
TRADING_DB = PROJECT_ROOT / "data" / "research.duckdb"

mcp_client = MultiServerMCPClient({
    "trading_mcp": {
        "command": "python3",
        "args": [str(TRADING_MCP), f"--db-path={TRADING_DB}"],
        "transport": "stdio",
    }
})


async def build_agent():
    with logfire.span("agent.load_mcp_tools"):
        mcp_tools = await mcp_client.get_tools()
        logfire.info(
            "loaded {n} MCP tools: {names}",
            n=len(mcp_tools),
            names=[t.name for t in mcp_tools],
        )

    with logfire.span("agent.build"):
        return create_deep_agent(
            model="anthropic:claude-sonnet-4-6",
            backend=FilesystemBackend(root_dir=str(PROJECT_ROOT), virtual_mode=True),
            skills=["/skills/trading-only/"],
            tools=mcp_tools,
        )


def _to_prompt(item: dict[str, Any]) -> str:
    if "prompt" in item:
        return item["prompt"]
    return " ".join(f"{k}={v}" for k, v in item.items())


def _thread_id(item: dict[str, Any]) -> str:
    sym = item.get("symbol", "")
    d = item.get("date", "")
    return f"{sym}-{d}" if sym or d else "default"


async def run_one(agent, item: dict[str, Any]) -> None:
    prompt = _to_prompt(item)
    thread_id = _thread_id(item)
    with logfire.span(
        "agent.invoke prompt={prompt!r}",
        prompt=prompt,
        thread_id=thread_id,
    ):
        try:
            await agent.ainvoke(
                {"messages": [{"role": "user", "content": prompt}]},
                config={"configurable": {"thread_id": thread_id}},
            )
        except Exception:
            logfire.exception("agent.ainvoke failed")
            raise


async def run_pipeline(
    inputs: Iterable[dict[str, Any]],
    concurrency: int = 3,
) -> None:
    items = list(inputs)
    with logfire.span(
        "pipeline.run n={n} concurrency={concurrency}",
        n=len(items),
        concurrency=concurrency,
    ):
        agent = await build_agent()
        sem = asyncio.Semaphore(concurrency)

        async def bounded(item: dict[str, Any]) -> None:
            async with sem:
                await run_one(agent, item)

        await asyncio.gather(*(bounded(i) for i in items))
