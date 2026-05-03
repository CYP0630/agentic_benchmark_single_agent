from langchain.agents import create_agent
from dotenv import load_dotenv
from src.pipeline import run_pipeline
load_dotenv(".env")

def get_weather(city: str) -> str:
    """Get weather for a given city."""
    return f"It's always sunny in {city}!"

agent = create_agent(
    model="fireworks:accounts/fireworks/models/kimi-k2p6",
    tools=[get_weather],
    system_prompt="You are a helpful assistant",
)

result = agent.invoke(
    {"messages": [{"role": "user", "content": "What's the weather in San Francisco?"}]}
)
print(result["messages"][-1].content_blocks)