"""Gateway tools that bootstrap discovery through AgentCore semantic search."""

import json
import os
import uuid

import httpx
from mcp_proxy_for_aws.sigv4_helper import SigV4HTTPXAuth, create_aws_session
from strands import tool

EXPECTED_TOOLS = {"BankProfile___get_client_profile", "BankTransfer___transfer_funds"}


def _auth() -> SigV4HTTPXAuth:
    aws_session = create_aws_session()
    return SigV4HTTPXAuth(
        aws_session.get_credentials(), "bedrock-agentcore", aws_session.region_name
    )


async def _rpc(policy_session_id: str, method: str, params: dict) -> dict:
    """Call AgentCore's stateless Streamable HTTP MCP endpoint directly."""
    async with httpx.AsyncClient(auth=_auth(), timeout=30) as client:
        common = {
            "accept": "application/json, text/event-stream",
            "content-type": "application/json",
            "mcp-protocol-version": "2025-03-26",
            "x-amzn-bedrock-agentcore-policy-session-id": policy_session_id,
        }
        initialize = await client.post(os.environ["BANK_GATEWAY_URL"], headers=common, json={"jsonrpc":"2.0","id":str(uuid.uuid4()),"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"temporal-policy-runtime","version":"1.0"}}})
        initialize.raise_for_status()
        mcp_session_id = initialize.headers.get("mcp-session-id")
        if mcp_session_id:
            common["mcp-session-id"] = mcp_session_id
        initialized = await client.post(os.environ["BANK_GATEWAY_URL"], headers=common, json={"jsonrpc":"2.0","method":"notifications/initialized","params":{}})
        initialized.raise_for_status()
        response = await client.post(
            os.environ["BANK_GATEWAY_URL"],
            headers=common,
            json={"jsonrpc": "2.0", "id": str(uuid.uuid4()), "method": method, "params": params},
        )
    response.raise_for_status()
    payload = response.json()
    if "error" in payload:
        raise RuntimeError(f"Gateway {method} failed: {payload['error']}")
    return payload["result"]


async def _call(policy_session_id: str, name: str, arguments: dict) -> dict:
    """Discover target tools semantically, then call an allow-listed one."""
    discovery = await _rpc(
        policy_session_id,
        "tools/call",
        {"name": "x_amz_bedrock_agentcore_search", "arguments": {"query": "get client profile and transfer funds"}},
    )
    if name not in EXPECTED_TOOLS or name not in json.dumps(discovery, default=str):
        raise RuntimeError(f"Gateway semantic discovery did not expose {name}.")
    return await _rpc(policy_session_id, "tools/call", {"name": name, "arguments": arguments})


def get_bank_gateway_tools(policy_session_id: str):
    """Return schema-safe Strands tools backed by discovered MCP names."""
    @tool
    async def get_client_profile(profile_id: str) -> dict:
        """Return the authoritative account number for a client profile."""
        return await _call(policy_session_id, "BankProfile___get_client_profile", {"profile_id": profile_id})

    @tool
    async def transfer_funds(profile_id: str, to_account: str, amount: int) -> dict:
        """Request a transfer after Gateway authorization has approved it."""
        return await _call(
            policy_session_id,
            "BankTransfer___transfer_funds",
            {"profile_id": profile_id, "to_account": to_account, "amount": amount},
        )

    return [get_client_profile, transfer_funds]
