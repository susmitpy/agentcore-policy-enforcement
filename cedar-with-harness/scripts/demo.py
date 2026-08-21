#!/usr/bin/env python3
"""Invoke the managed Harness with an IAM principal and a UUID session ID."""

import os
import uuid
from pathlib import Path

import boto3
from dotenv import load_dotenv

DEPLOYMENT_ENV = Path(__file__).resolve().parent.parent / ".agentcore-work" / "deployment.env"
load_dotenv(DEPLOYMENT_ENV)

PROMPTS = [
    "Make a utility payment of 250 INR",
    "Make a vendor invoice payment of 2500 INR",
]


def main() -> int:
    harness_arn = os.getenv("PAYMENT_HARNESS_ARN")
    region = os.getenv("AWS_REGION")
    if not harness_arn or not region:
        raise SystemExit(
            "Deploy first so .agentcore-work/deployment.env contains PAYMENT_HARNESS_ARN and AWS_REGION."
        )

    for prompt in PROMPTS:
        session_id = str(uuid.uuid4())
        print(f"\n--- session {session_id} ---\n{prompt}")
        client = boto3.client("bedrock-agentcore", region_name=region)
        response = client.invoke_harness(
            harnessArn=harness_arn,
            runtimeSessionId=session_id,
            messages=[{"role": "user", "content": [{"text": prompt}]}],
        )
        for event in response["stream"]:
            print(event)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
