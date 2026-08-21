# Temporal Gateway Policy Demo

This self-contained demo proves an important distinction: an agent supplying a
matching `profile_id` and `to_account` does not prove that the account came
from the profile service. The transfer is permitted only when a successful
profile response returned the exact `(profile_id, account_number)` pair in the
previous 15 minutes. It also demonstrates an eight-hour, per-profile transfer
cap of 5,000 units.

It uses [Dogwood](https://github.com/dogwood-policy/dogwood)'s temporal-policy
reference interpreter to validate and replay the policy locally, and Amazon
Bedrock AgentCore Policy accepts the same Dogwood source for Gateway
enforcement. The two Python functions are simulated Gateway-target contracts:
they make no network calls, persist no data, and never move money.

> AgentCore Policy added Dogwood temporal-policy support on 6 August 2026.
> When this policy is attached to an AgentCore Gateway in `ENFORCE` mode,
> AgentCore stores the authenticated principal's Gateway events for each policy
> session and evaluates the policy before the target runs. No DynamoDB, durable
> function, or application-managed event store is required.

## What is enforced

The two policy templates in `policies/` become separate AgentCore
policy resources because the service accepts one statement per resource:

1. `BankProfile___get_client_profile` is allowed so a trusted response can enter the
   event history.
2. `BankTransfer___transfer_funds` is allowed only after a matching profile
   **response** and when the request stays within the 5,000-unit cap for that
   profile in the preceding eight hours.

The temporal selector in
`policies/transfer_amount_limit.template.dw`
pins both `output.profile_id` and
`output.account_number` to the transfer request and also pins `eventResource`
to the current Gateway. `output.` is intentional: matching a prior lookup's
input would let an agent invent a matching account after the fact.

The included event schema retains eight hours of events and pins
`callerPrincipal` on every event kind, so a different caller's lookup or
transfer cannot affect this caller's decision. The integrity policy retains
its explicit 15-minute lookup window.

## Prerequisites & Configuration

Install and authenticate these tools:

```bash
aws --version
node --version     # Node.js 20+
python3 --version  # Python 3.12 recommended
npm install -g @aws/agentcore
aws bedrock-agentcore-control help # Check aws cli version
agentcore --help
aws sts get-caller-identity
```

Choose an AWS region that supports AgentCore temporal policies (e.g., `ap-south-1`). Your deployment principal needs permission to manage Lambda, CloudFormation, S3 artifacts, and AgentCore (Harness, Gateway, Policy, Identity, Runtime).

From the project directory, set up the Python virtual environment and configure your shell:

```bash
cd agent_core_harness/agentcore-payment-harness/temporal-dogwood-with-runtime

# Set up the Python virtual environment
uv venv
source .venv/bin/activate
uv sync

export AWS_REGION=ap-south-1
export ARTIFACT_BUCKET=replace-with-your-artifact-bucket
export GEMINI_API_KEY=replace-with-your-google-ai-api-key
```

Optional names:

```bash
export STACK_NAME=agentcore-temporal-demo
```

## Local Validation / Replays

The simulated Lambda contracts and repository artifacts can be tested with only Python:

```bash
python3 -m unittest discover -s tests -v
```

To validate and replay the temporal policy locally without AWS deployment, install Dogwood's CLI from its source repository (Rust 1.90+ and Cargo are required):

```bash
cargo install --git https://github.com/dogwood-policy/dogwood.git amzn-dogwood-cli
./scripts/replay.sh
```

`replay.sh` validates the schemas, renders the two deployment templates into a temporary combined policy, and runs all three local traces testing the ALLOW/DENY logic:

| Trace | Expected transfer decision |
| --- | --- |
| `traces/matching_account.log` | `ALLOW` — `abc` was returned for `xyz` |
| `traces/invented_account.log` | `DENY` — the agent substituted `ghi` after the lookup |
| `traces/transfer_amount_limit.log` | first 5,000-unit transfer is `ALLOW`; second 5,000-unit transfer to `xyz` is `DENY` |

The profile lookup itself is allowed in both traces; a `response` is a history-only event, and only a `request` causes an authorization decision.

## Deploy

The deployment creates a standalone AgentCore Runtime, two Python 3.12 Lambdas, one IAM-authenticated MCP Gateway (`BankGateway`) with two Lambda targets (`BankProfile` and `BankTransfer`), and a Dogwood policy engine in `ENFORCE` mode. The actions in the deployed policy are therefore `BankProfile___get_client_profile` and `BankTransfer___transfer_funds`.

Ensure the deployment scripts are executable, then run the deploy script:

```bash
chmod +x scripts/deploy.sh scripts/demo.py scripts/list_tools.py scripts/replay.sh
./scripts/deploy.sh
```

The script performs these stages:
1. Packages and deploys the Profile and Transfer Lambda targets.
2. Creates an AgentCore Runtime (custom Python `Strands` app), registers your Gemini key, sets up the `BankGateway` (MCP), and adds the Lambdas as targets.
3. Renders the Dogwood policy templates (`allow_profile_lookup` and `transfer_amount_limit`) with the resolved Gateway ARN and caller principal.
4. Adds the policies in `ACTIVE`/`ENFORCE` mode and updates the deployed project.
5. Grants the Gateway role permission to obtain a workload access token, required before the Gateway can invoke its Lambda targets.

Generated deployment values are written to `.agentcore-work/deployment.env`; do not commit that file.

## Verify / Invoke

### Verify the Gateway Tools

First record raw MCP discovery, without Strands or the runtime in the path:

```bash
python3 scripts/list_tools.py
```

With AgentCore semantic search enabled, `tools/list` intentionally returns an empty list. Use the diagnostic's semantic-search mode instead:

```bash
python3 scripts/list_tools.py --search 'get client profile and transfer funds'
```

It must return `BankProfile___get_client_profile` and `BankTransfer___transfer_funds`. The runtime follows this same discovery pattern before calling either action.

### Invoke the Runtime

The runtime system prompt is deliberately only one line: when a transfer has a profile ID, fetch the account ID first. `scripts/demo.py` runs a permitted transfer, an adversarial fabricated-account request, and a same-session cap scenario, giving **each Runtime invocation a fresh UUID session**.

```bash
python3 scripts/demo.py
```

Within an invocation, the Runtime calls both Gateway tools and AgentCore applies temporal policy to that tool-call trajectory.

1. **Normal flow**: The first prompt asks to transfer to profile `xyz`: the Runtime looks up the authoritative account `abc` and the simulated transfer is permitted.
2. **Forged input**: The second prompt asks it to look up `xyz` but then use fabricated account `ghi`. If the model complies with that malicious instruction after the lookup, the Gateway denies the transfer because `ghi` was not in the lookup response. The tool-call denial appears in the streamed Harness events.
3. **Rate limits**: The third prompt asks for two sequential 5,000-unit transfers to `xyz` in one Runtime session. The first is permitted; after its successful response enters policy history, the Gateway denies the second request because the eight-hour per-profile cap has been reached.

Each list item is intentionally an independent Runtime session; do not reuse a session UUID between them. The runtime propagates that value as the documented Gateway policy-session header.

## Gateway contracts

The Gateway has two independent Lambda targets, so it uses one schema per
target: `profile_tools.json` and
`transfer_tools.json`. Together they define:

```text
get_client_profile({ profile_id })
  -> { profile_id, account_number, name }

transfer_funds({ profile_id, to_account, amount })
  -> { transfer_id, status }
```

The transfer function deliberately has no account/profile validation. In a
real integration, attach this policy to the Gateway in `ENFORCE` mode; the
Gateway returns the allow/deny decision before it invokes the target. Do not
use the in-process Python functions as an authorization boundary.

## Policy source layout

`allow_profile_lookup.template.dw` and `transfer_amount_limit.template.dw` are
the policy sources. Deployment renders each with the concrete Gateway ARN and
Runtime role; local replay renders both with fixed demo values into a temporary
file. This avoids keeping a stale duplicate `.dw` policy in the repository.

The `BankProfile___…` and `BankTransfer___…` action names must match the
Gateway target/tool names in the deployed schemas.

The runtime passes the same `x-amzn-bedrock-agentcore-policy-session-id` header
on the profile lookup and dependent transfer. AgentCore scopes the trajectory
to the authenticated principal plus that policy-session ID, records a
`response` only after the permitted profile call completes, and retains
temporal history for up to 24 hours. A policy or policy-engine change
invalidates active policy sessions, so start a new session after updating this
policy.

The profile lookup must remain permitted: a denied lookup is recorded as an
`error`, not a `response`, and cannot satisfy the transfer predicate. The
15-minute window in this policy is intentionally tighter than AgentCore's
maximum 24-hour history window.

## Cleanup

The teardown wrapper deletes the generated AgentCore CloudFormation stack, generated local state, and its dedicated Gemini credential provider:

```bash
./scripts/destroy.sh
```
