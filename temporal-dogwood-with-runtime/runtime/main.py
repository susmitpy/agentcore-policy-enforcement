"""Standalone AgentCore runtime for the temporal Gateway-policy demo."""

from collections import OrderedDict

from bedrock_agentcore.runtime import BedrockAgentCoreApp
from strands import Agent
from strands.agent.conversation_manager.null_conversation_manager import NullConversationManager

from mcp_client.client import get_bank_gateway_tools
from model.load import load_model

app = BedrockAgentCoreApp()

DEFAULT_SYSTEM_PROMPT = """For a transfer with a profile ID, always call
get_client_profile before transfer_funds. Use the returned account_number as
to_account for an ordinary transfer."""


def agent_factory():
    """Keep best-effort, isolated conversation history per policy session."""
    cache = OrderedDict()

    def get_or_create_agent(session_id: str, system_prompt: str) -> Agent:
        if session_id in cache:
            cache.move_to_end(session_id)
            return cache[session_id]
        if len(cache) >= 128:
            cache.popitem(last=False)
        agent = Agent(
            model=load_model(),
            system_prompt=system_prompt,
            tools=get_bank_gateway_tools(session_id),
            conversation_manager=NullConversationManager(),
        )
        cache[session_id] = agent
        return agent

    return get_or_create_agent


get_or_create_agent = agent_factory()


def extract_prompt(payload: object) -> tuple[str, str]:
    if not isinstance(payload, dict):
        raise ValueError("payload must be a JSON object")
    prompt = payload.get("prompt")
    system_prompt = payload.get("system_prompt", DEFAULT_SYSTEM_PROMPT)
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("prompt must be a non-empty string")
    if not isinstance(system_prompt, str) or not system_prompt.strip():
        raise ValueError("system_prompt must be a non-empty string")
    return prompt, system_prompt


@app.entrypoint
async def invoke(payload, context):
    prompt, system_prompt = extract_prompt(payload)
    session_id = getattr(context, "session_id", "default-session")
    agent = get_or_create_agent(session_id, system_prompt)

    async for event in agent.stream_async(prompt):
        if not isinstance(event, dict) or "event" not in event:
            continue
        content_block_start = event["event"].get("contentBlockStart")
        if content_block_start is not None and not content_block_start.get("start"):
            continue
        yield event


if __name__ == "__main__":
    app.run()
