#!/usr/bin/env python3
"""List an AgentCore Gateway's raw MCP tools using SigV4 authentication.

This intentionally talks to the Gateway directly, bypassing Strands and the
runtime.  It is the fault-boundary diagnostic for target-to-tool mapping.
"""

import argparse
import json
import os
import uuid
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from dotenv import load_dotenv


DEPLOYMENT_ENV = Path(__file__).resolve().parent.parent / ".agentcore-work" / "deployment.env"


def signed_post(url: str, payload: dict, region: str, session_id: str | None) -> tuple[dict, dict]:
    """POST one JSON-RPC request and return its JSON response and headers."""
    body = json.dumps(payload).encode()
    headers = {
        "accept": "application/json, text/event-stream",
        "content-type": "application/json",
        "mcp-protocol-version": "2025-03-26",
    }
    if session_id:
        headers["mcp-session-id"] = session_id

    session = boto3.Session(region_name=region)
    credentials = session.get_credentials()
    if credentials is None:
        raise RuntimeError("No AWS credentials were found for the selected profile.")
    aws_request = AWSRequest(method="POST", url=url, data=body, headers=headers)
    SigV4Auth(credentials.get_frozen_credentials(), "bedrock-agentcore", region).add_auth(aws_request)

    request = Request(url, data=body, method="POST", headers=dict(aws_request.headers.items()))
    try:
        with urlopen(request) as response:  # nosec B310 -- the endpoint is supplied by AgentCore
            response_body = response.read().decode()
            return (json.loads(response_body) if response_body else {}), dict(response.headers.items())
    except HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise RuntimeError(f"MCP request failed ({error.code}): {detail}") from error


def main() -> int:
    load_dotenv(DEPLOYMENT_ENV)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gateway-url", default=os.getenv("BANK_GATEWAY_URL"))
    parser.add_argument("--region", default=os.getenv("AWS_REGION"))
    parser.add_argument("--search", help="Also query AgentCore's semantic tool-search endpoint.")
    args = parser.parse_args()
    if not args.gateway_url or not args.region:
        raise SystemExit("Pass --gateway-url/--region, or deploy first to create deployment.env.")

    # The AgentCore Gateway URL already contains its MCP path. Accept either
    # the complete URL written by deploy.sh or a base Gateway URL for manual use.
    url = args.gateway_url.rstrip("/")
    if not url.endswith("/mcp"):
        url += "/mcp"
    initialize, headers = signed_post(
        url,
        {
            "jsonrpc": "2.0",
            "id": str(uuid.uuid4()),
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": {"name": "temporal-demo-diagnostic", "version": "1.0"},
            },
        },
        args.region,
        None,
    )
    mcp_session_id = headers.get("Mcp-Session-Id") or headers.get("mcp-session-id")
    # AgentCore currently uses stateless Streamable HTTP and may omit this
    # optional MCP header.  In that case tools/list is a second signed request.
    signed_post(
        url,
        {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
        args.region,
        mcp_session_id,
    )
    tools, _ = signed_post(
        url,
        {"jsonrpc": "2.0", "id": str(uuid.uuid4()), "method": "tools/list", "params": {}},
        args.region,
        mcp_session_id,
    )
    if "error" in tools:
        raise RuntimeError(f"Gateway tools/list error: {tools['error']}")
    names = [tool["name"] for tool in tools.get("result", {}).get("tools", [])]
    result = {"gateway_url": url, "tool_names": names, "raw_response": tools}
    if args.search:
        search, _ = signed_post(
            url,
            {
                "jsonrpc": "2.0",
                "id": str(uuid.uuid4()),
                "method": "tools/call",
                "params": {
                    "name": "x_amz_bedrock_agentcore_search",
                    "arguments": {"query": args.search},
                },
            },
            args.region,
            mcp_session_id,
        )
        result["semantic_search"] = search
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
