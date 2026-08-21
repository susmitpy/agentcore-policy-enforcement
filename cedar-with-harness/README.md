# Minimal Cloud AgentCore Payment Demo

This is a demo on AWS. It creates **simulated** transactions only: there is no bank, wallet, balance, persistence, or real money movement.

```text
IAM caller -> AgentCore Harness (Gemini) -> AgentCore Gateway -> Cedar ENFORCE -> Payment Lambda
```

The managed Harness uses `gemini-3.5-flash-lite` and has exactly one tool: the IAM-authenticated `PaymentGateway`. Browser, code-interpreter, shell, and filesystem tools are not configured. The Gateway exposes only `PaymentTools___make_payment(purpose, amount)` and its Cedar engine default-denies every action except that tool with `amount <= 1000` (inclusive).

## Prerequisites & Configuration

Install and authenticate these tools:

```bash
aws --version
node --version     # Node.js 20+
python3 --version  # Python 3.12 recommended
npm install -g @aws/agentcore
aws bedrock-agentcore-control help # To check aws cli version - if you see unknown command, upgrade aws cli
agentcore --help
aws sts get-caller-identity
```

Choose an AWS region that supports Amazon Bedrock AgentCore, then create or choose an S3 bucket for CloudFormation packaging artifacts.

From the project directory, set up the Python virtual environment and configure your shell:

```bash
cd agent_core_harness/agentcore-payment-harness/cedar-with-harness

# Set up the Python virtual environment
uv venv
source .venv/bin/activate
uv sync

export AWS_REGION=ap-south-1
export ARTIFACT_BUCKET=replace-with-your-artifact-bucket
export GEMINI_API_KEY=replace-with-your-google-ai-api-key
```

Optional names, useful when deploying more than one isolated demo:

```bash
export STACK_NAME=agentcore-payment-harness
export GEMINI_CREDENTIAL_NAME=payment-demo-gemini-key
```

The wrapper stores `GEMINI_API_KEY` in an AgentCore Identity API-key credential provider (`payment-demo-gemini-key` by default); it never writes the raw key to the project. The deploying IAM principal needs CloudFormation/S3/Lambda/IAM permissions plus AgentCore Gateway, Policy, Harness, and Identity management permissions. In particular, creating Cedar policies requires `bedrock-agentcore:InvokeGateway` on the Gateway.

## Pre-deployment checks

Before deploying, review the simulated-purpose/account allowlist in `lambda/payment.py`. The only allowed purposes are currently demo-only identifiers and are not connected to any payment system:

| Purpose | Simulated approved account |
| --- | --- |
| `rent` | `acct_demo_rent_001` |
| `utilities` | `acct_demo_utilities_001` |
| `payroll` | `acct_demo_payroll_001` |
| `vendor_invoice` | `acct_demo_vendor_001` |

## Local Tests

No external Python packages are required.

```bash
python3 -m unittest discover -s tests -v
```

Expected result: four passing tests covering a valid payment, invalid purpose, malformed amount, and JSON output.

## Deploy

Ensure the deployment script is executable, then run it:

```bash
chmod +x scripts/deploy.sh scripts/demo.py
./scripts/deploy.sh
```

The script is deliberately two-phase:

1. Packages and deploys the simulated Payment Lambda.
2. Registers `GEMINI_API_KEY` in AgentCore Identity, unless the named provider already exists. Creates and deploys the managed Harness, IAM Gateway, Lambda target, and attached ENFORCE policy engine.
3. Resolves the concrete Gateway ARN, renders the Cedar resource statement, adds the one permit, adds the Harness Gateway tool, and redeploys.

AgentCore CLI creates a least-privilege Gateway target role for the Lambda target. Inspect that generated role after deployment and retain only `lambda:InvokeFunction` on `$PAYMENT_LAMBDA_ARN`. Do not give callers `bedrock-agentcore:InvokeGateway`.

On success it writes deployment values here:

```bash
cat .agentcore-work/deployment.env
```

`scripts/demo.py` reads this generated file automatically. Source it only when a shell command below needs one of its values. The AgentCore CLI project created by the wrapper is under `.agentcore-work/PaymentHarness`; it is generated state and intentionally ignored by Git.

## IAM Configuration

Copy `iam/caller-harness-only.json` to a caller-specific policy. Replace `REPLACE_WITH_HARNESS_ARN` with the `PAYMENT_HARNESS_ARN` value in `.agentcore-work/deployment.env`, then attach it to the IAM user or role that will invoke the demo.

The policy allows `InvokeHarness` and `InvokeAgentRuntime` only on this Harness, while explicitly denying `InvokeGateway` everywhere. Keep the deployment/admin role separate from caller roles, because the deployer needs broader Gateway/Policy permissions.

## Invoke & Observability

The public Harness interface is a user message plus a UUID session ID. `scripts/demo.py` creates a UUID for each request and reads the Harness ARN and AWS Region from the generated `.agentcore-work/deployment.env`; do not add deployment output to `.env`.

Invoke the managed Harness as the caller role. The script iterates over a set of predefined test prompts:

```bash
python3 scripts/demo.py
```

Successful tool output includes `status: simulated`, a `sim_...` transaction ID, allowlisted account ID, amount, and UTC timestamp. Amounts are whole INR values. Fractional values, amounts above 1000, calls to any other action, and prompt-injection text cannot bypass the Gateway validation and Cedar policy before the Lambda is invoked.

For a direct integration check, use the AgentCore CLI only with a principal **without** the caller deny policy and IAM-sign the Gateway request. The normal caller role should receive AccessDenied before a Gateway call reaches Cedar.

Check logs/traces:

```bash
aws logs tail "/aws/lambda/${STACK_NAME:-agentcore-payment-harness}-payment" --follow
```

Run permitted integration checks at INR 250 and INR 1000. Then verify INR 1001, a fractional amount, and a prompt-injection request cause no matching Lambda log. AgentCore Gateway policy decisions are emitted in AgentCore/CloudWatch traces; fetch the Gateway ID with `agentcore status --json` from `.agentcore-work/PaymentHarness` and inspect its Gateway log group.

## Cleanup

Run the teardown wrapper to delete the AgentCore project, Lambda stack, generated local state, and its dedicated Gemini credential provider:

```bash
./scripts/destroy.sh
```

`GEMINI_CREDENTIAL_NAME` must be dedicated to this harness: the wrapper deletes it. Empty deployment artifacts from `$ARTIFACT_BUCKET` according to your retention policy.
