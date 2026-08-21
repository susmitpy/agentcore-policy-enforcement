#!/usr/bin/env bash
# Deploys the Lambda first, then performs AgentCore's required two-phase Cedar deploy.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$root_dir/.env" ]]; then
  set -a
  source "$root_dir/.env"
  set +a
fi

work_dir="$root_dir/.agentcore-work"
project_dir="$work_dir/PaymentHarness"
stack_name="${STACK_NAME:-agentcore-payment-harness}"
region="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
agentcore_bin="${AGENTCORE_BIN:-agentcore}"

[[ -n "$region" ]] || { echo "Set AWS_REGION or configure an AWS default region." >&2; exit 2; }
[[ -n "${GEMINI_API_KEY:-}" ]] || { echo "Set GEMINI_API_KEY before deployment." >&2; exit 2; }
command -v aws >/dev/null || { echo "Install AWS CLI v2." >&2; exit 2; }
command -v "$agentcore_bin" >/dev/null || {
  echo "Install AgentCore CLI first: npm install -g @aws/agentcore" >&2; exit 2;
}

mkdir -p "$work_dir"

# Package/deploy only the simulated Lambda. No money movement credentials exist in this stack.
aws cloudformation package --region "$region" --template-file "$root_dir/template.yaml" \
  --s3-bucket "${ARTIFACT_BUCKET:?Set ARTIFACT_BUCKET to an S3 bucket for CloudFormation artifacts}" \
  --output-template-file "$work_dir/packaged.yaml"
aws cloudformation deploy --region "$region" --stack-name "$stack_name" \
  --template-file "$work_dir/packaged.yaml" --capabilities CAPABILITY_IAM
lambda_arn="$(aws cloudformation describe-stacks --region "$region" --stack-name "$stack_name" \
  --query 'Stacks[0].Outputs[?OutputKey==`PaymentFunctionArn`].OutputValue' --output text)"

# AgentCore Identity holds the raw Gemini key. The harness receives only this ARN.
credential_name="${GEMINI_CREDENTIAL_NAME:-payment-demo-gemini-key}"
credential_arn="$(CREDENTIAL_NAME="$credential_name" aws bedrock-agentcore-control list-api-key-credential-providers --region "$region" --output json \
  | CREDENTIAL_NAME="$credential_name" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
n = os.environ["CREDENTIAL_NAME"]
providers = d.get("credentialProviders", []) + d.get("apiKeyCredentialProviders", []) + d.get("items", [])
print(next((p.get("apiKeyArn") or p.get("credentialProviderArn") or "" for p in providers if p.get("name") == n), ""))
')"
if [[ ! "$credential_arn" =~ ^arn:aws:bedrock-agentcore:[a-z0-9-]+:[0-9]{12}:token-vault/[a-zA-Z0-9.-]+/apikeycredentialprovider/[a-zA-Z0-9.-]+$ ]]; then
  credential_arn="$(aws bedrock-agentcore-control create-api-key-credential-provider --region "$region" \
    --name "$credential_name" --api-key "$GEMINI_API_KEY" --output json \
    | python3 -c 'import json, sys; d=json.load(sys.stdin); print(d.get("apiKeyArn") or d.get("credentialProviderArn") or "")')"
fi
[[ "$credential_arn" =~ ^arn:aws:bedrock-agentcore:[a-z0-9-]+:[0-9]{12}:token-vault/[a-zA-Z0-9.-]+/apikeycredentialprovider/[a-zA-Z0-9.-]+$ ]] || {
  echo "Unable to resolve a valid AgentCore API-key credential-provider ARN." >&2
  exit 2
}

if [[ ! -f "$project_dir/agentcore/agentcore.json" ]]; then
  (
    cd "$work_dir"
    "$agentcore_bin" create --name PaymentHarness --model-provider gemini \
      --model-id gemini-3.5-flash-lite --api-key-arn "$credential_arn" --no-harness-memory --skip-git
  )
  # The CLI creates the managed Harness; add exactly one Gateway tool, no browser/code tools.
  (
    cd "$project_dir"
    "$agentcore_bin" add policy-engine --name PaymentPolicyEngine \
      --description 'Default-deny policy for the simulated payment tool' \
      --attach-to-gateways PaymentGateway --attach-mode ENFORCE
    "$agentcore_bin" add gateway --name PaymentGateway --authorizer-type AWS_IAM \
      --policy-engine PaymentPolicyEngine --policy-engine-mode ENFORCE
    "$agentcore_bin" add gateway-target --name PaymentTools --type lambda-function-arn \
      --lambda-arn "$lambda_arn" --tool-schema-file "$root_dir/payment_tools.json" --gateway PaymentGateway
    "$agentcore_bin" deploy --yes
  )
fi

# Older CLI/API combinations can serialize a successful create response as
# "None". Keep the generated project usable when the wrapper is rerun.
harness_config="$project_dir/app/PaymentHarness/harness.json"
if [[ -f "$harness_config" ]]; then
  CREDENTIAL_ARN="$credential_arn" HARNESS_CONFIG="$harness_config" MODEL_ID="gemini-3.5-flash-lite" python3 -c '
import json, os
path = os.environ["HARNESS_CONFIG"]
with open(path) as f:
    config = json.load(f)
model = config.setdefault("model", {})
if (model.get("apiKeyArn") != os.environ["CREDENTIAL_ARN"] or
        model.get("modelId") != os.environ["MODEL_ID"]):
    model["apiKeyArn"] = os.environ["CREDENTIAL_ARN"]
    model["modelId"] = os.environ["MODEL_ID"]
    with open(path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
'
fi

# AgentCore Harnesses load their behavioral instructions from this generated
# file. Keep it sourced from the repository so re-deployments do not revert
# the whole-INR requirement needed by the Gateway's Cedar Long input.
harness_prompt="$project_dir/app/PaymentHarness/system-prompt.md"
if [[ -f "$harness_prompt" ]]; then
  cp "$root_dir/harness_system_prompt.md" "$harness_prompt"
fi

# A previous first deployment may have failed after project creation. Deploy the
# local-only base resources before asking status for a gateway ARN.
if (
  cd "$project_dir"
  "$agentcore_bin" status --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
base_types = {"gateway", "policy-engine", "harness"}
raise SystemExit(0 if any(r.get("resourceType") in base_types and r.get("deploymentState") == "local-only" for r in d.get("resources", [])) else 1)
'
); then
  (
    cd "$project_dir"
    "$agentcore_bin" deploy --yes
  )
fi

# Cedar cannot use a wildcard resource, so resolve the deployed gateway and add the exact ARN.
gateway_arn="$(cd "$project_dir" && "$agentcore_bin" status --json | python3 -c '
import json, sys
d=json.load(sys.stdin)
def walk(x):
    if isinstance(x, dict):
        for k,v in x.items():
            if k == "gatewayArn" and isinstance(v,str) and ":gateway/" in v: print(v); return True
            if walk(v): return True
    elif isinstance(x,list):
        for v in x:
            if walk(v): return True
    return False
if not walk(d): raise SystemExit("PaymentGateway ARN not found in agentcore status")
')"
policy_file="$work_dir/payment_limit.cedar"
sed "s|{{GATEWAY_ARN}}|$gateway_arn|g" "$root_dir/policies/payment_limit.cedar.template" > "$policy_file"

if ! PROJECT_CONFIG="$project_dir/agentcore/agentcore.json" python3 -c '
import json, os
with open(os.environ["PROJECT_CONFIG"]) as f:
    config = json.load(f)
found = any(
    policy.get("name") == "PaymentAmountAtMost1000"
    for engine in config.get("policyEngines", [])
    for policy in engine.get("policies", [])
)
raise SystemExit(0 if found else 1)
'; then
  (
    cd "$project_dir"
    # A local gateway name is resolvable only after the first deployment. The
    # tool already exists when repairing or migrating a policy, so do not add
    # a duplicate Harness tool in that case.
    if ! python3 -c '
import json
with open("app/PaymentHarness/harness.json") as f:
    tools = json.load(f).get("tools", [])
raise SystemExit(0 if any(t.get("name") == "payment-gateway" for t in tools) else 1)
'; then
      "$agentcore_bin" add tool --harness PaymentHarness --type agentcore_gateway \
        --name payment-gateway --gateway PaymentGateway
    fi
    "$agentcore_bin" add policy --name PaymentAmountAtMost1000 --engine PaymentPolicyEngine --source "$policy_file"
    "$agentcore_bin" deploy --yes
  )
else
  # Keep an existing local policy synchronized with its rendered Cedar source
  # so a corrected policy can be deployed after an earlier failed attempt.
  POLICY_FILE="$policy_file" PROJECT_CONFIG="$project_dir/agentcore/agentcore.json" python3 -c '
import json, os
path = os.environ["PROJECT_CONFIG"]
with open(path) as f:
    config = json.load(f)
statement = open(os.environ["POLICY_FILE"]).read().rstrip()
for engine in config.get("policyEngines", []):
    for policy in engine.get("policies", []):
        if policy.get("name") == "PaymentAmountAtMost1000":
            policy["statement"] = statement
            policy["sourceFile"] = os.environ["POLICY_FILE"]
with open(path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
'
  (
    cd "$project_dir"
    "$agentcore_bin" deploy --yes
  )
fi

harness_arn="$(cd "$project_dir" && "$agentcore_bin" status --json | python3 -c '
import json, sys
d=json.load(sys.stdin)
def walk(x):
    if isinstance(x, dict):
        for k,v in x.items():
            if k == "harnessArn" and isinstance(v,str): print(v); return True
            if walk(v): return True
    elif isinstance(x,list):
        for v in x:
            if walk(v): return True
    return False
if not walk(d): raise SystemExit("Harness ARN not found in agentcore status")
')"
printf 'AWS_REGION=%s\nPAYMENT_LAMBDA_ARN=%s\nPAYMENT_GATEWAY_ARN=%s\nPAYMENT_HARNESS_ARN=%s\n' \
  "$region" "$lambda_arn" "$gateway_arn" "$harness_arn" > "$work_dir/deployment.env"
echo "Deployed. Source $work_dir/deployment.env"
echo "Attach iam/caller-harness-only.json after replacing REPLACE_WITH_HARNESS_ARN with: $harness_arn"
