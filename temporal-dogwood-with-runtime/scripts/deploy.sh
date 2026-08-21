#!/usr/bin/env bash
# Deploy one aggregated Gateway with independent profile and transfer targets.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$root_dir/.env" ]] && { set -a; source "$root_dir/.env"; set +a; }
work_dir="$root_dir/.agentcore-work"
project_dir="$work_dir/TemporalPolicyDemo"
region="${AWS_REGION:-$(aws configure get region)}"
stack_name="${STACK_NAME:-agentcore-temporal-demo}"
ac="${AGENTCORE_BIN:-agentcore}"

[[ -n "$region" ]] || { echo "Set AWS_REGION or configure an AWS default region." >&2; exit 2; }
mkdir -p "$work_dir"
aws cloudformation package --region "$region" --template-file "$root_dir/template.yaml" --s3-bucket "${ARTIFACT_BUCKET:?Set ARTIFACT_BUCKET}" --output-template-file "$work_dir/packaged.yaml"
aws cloudformation deploy --region "$region" --stack-name "$stack_name" --template-file "$work_dir/packaged.yaml" --capabilities CAPABILITY_IAM
profile_arn="$(aws cloudformation describe-stacks --region "$region" --stack-name "$stack_name" --query 'Stacks[0].Outputs[?OutputKey==`ProfileFunctionArn`].OutputValue' --output text)"
transfer_arn="$(aws cloudformation describe-stacks --region "$region" --stack-name "$stack_name" --query 'Stacks[0].Outputs[?OutputKey==`TransferFunctionArn`].OutputValue' --output text)"

if [[ ! -f "$project_dir/agentcore/agentcore.json" ]]; then
  "$ac" create --name TemporalPolicyDemo --project-name TemporalPolicyDemo --no-agent --skip-git --output-dir "$work_dir"
  (
    cd "$project_dir"
    "$ac" add agent --name TemporalPolicyAgent --type byo --build CodeZip --language Python --framework Strands --model-provider Gemini --code-location "$root_dir/runtime" --entrypoint main.py --network-mode PUBLIC --authorizer-type AWS_IAM
    "$ac" add credential --name temporal-demo-gemini-key --type api-key --api-key "$GEMINI_API_KEY"
    "$ac" add policy-engine --name BankPolicyEngine --description temporal
    "$ac" add gateway --name BankGateway --protocol-type MCP --authorizer-type AWS_IAM --policy-engine BankPolicyEngine --policy-engine-mode ENFORCE
    "$ac" add gateway-target --name BankProfile --gateway BankGateway --type lambda-function-arn --lambda-arn "$profile_arn" --tool-schema-file "$root_dir/profile_tools.json"
    "$ac" add gateway-target --name BankTransfer --gateway BankGateway --type lambda-function-arn --lambda-arn "$transfer_arn" --tool-schema-file "$root_dir/transfer_tools.json"
    "$ac" deploy --yes
  )
fi

status="$(cd "$project_dir" && "$ac" status --json)"
eval "$(STATUS="$status" python3 -c '
import json, os
r = json.loads(os.environ["STATUS"])["deployedState"]["targets"]["default"]["resources"]
g = r.get("mcp", {}).get("gateways", r.get("gateways", {}))["BankGateway"]
print("BARN=" + repr(g["gatewayArn"]))
print("BURL=" + repr(g["gatewayUrl"]))
print("ROLE=" + repr(r["runtimes"]["TemporalPolicyAgent"]["roleArn"]))
')"
# AgentCore's Cedar IamEntity for a SigV4 assumed role is the stable STS role
# ARN without the ephemeral session-name component. Render that exact entity;
# do not permit every IamEntity or match a session ARN.
lookup_principal="$(ROLE="$ROLE" python3 -c '
import os
role = os.environ["ROLE"]
prefix, role_name = role.split(":role/", 1)
print(prefix.replace(":iam:", ":sts:") + ":assumed-role/" + role_name)
')"
# AgentCore returns the complete MCP endpoint (including the /mcp suffix).
# Do not append it again: /mcp/mcp is not a supported Gateway operation.
PROJECT="$project_dir/agentcore/agentcore.json" BURL="$BURL" python3 -c '
import json, os
path = os.environ["PROJECT"]
with open(path) as f: project = json.load(f)
project["runtimes"][0]["envVars"] = [{"name": "BANK_GATEWAY_URL", "value": os.environ["BURL"]}]
with open(path, "w") as f: json.dump(project, f, indent=2); f.write("\n")
'
sed -e "s|{{BANK_GATEWAY_ARN}}|$BARN|g" -e "s|{{LOOKUP_PRINCIPAL}}|$lookup_principal|g" "$root_dir/policies/allow_profile_lookup.template.dw" > "$work_dir/profile.dw"
sed -e "s|{{BANK_GATEWAY_ARN}}|$BARN|g" -e "s|{{LOOKUP_PRINCIPAL}}|$lookup_principal|g" \
    "$root_dir/policies/transfer_amount_limit.template.dw" > "$work_dir/transfer-limit.dw"

# On a repeat deploy, update every rendered statement in the declarative
# source before deploying. The transfer cap also enforces account integrity,
# because separate permit policies are additive rather than conjunctive.
PROFILE="$work_dir/profile.dw" TRANSFER_LIMIT="$work_dir/transfer-limit.dw" PROJECT="$project_dir/agentcore/agentcore.json" python3 - <<'PY'
import json
import os

path = os.environ["PROJECT"]
with open(path) as f:
    project = json.load(f)
rendered_policies = {
    "AllowProfileLookup": os.environ["PROFILE"],
    "TransferAmountLimit": os.environ["TRANSFER_LIMIT"],
}
changed = False
for engine in project.get("policyEngines", []):
    # TransferAmountLimit now combines the cap and output-to-input integrity.
    # Remove the legacy standalone permit, which would otherwise bypass the
    # cap due to Cedar's permit-is-additive evaluation.
    engine["policies"] = [
        policy for policy in engine.get("policies", [])
        if policy.get("name") != "OutputToInputIntegrity"
    ]
    for policy in engine.get("policies", []):
        source = rendered_policies.get(policy.get("name"))
        if source:
            with open(source) as f:
                policy["statement"] = f.read()
            policy["sourceFile"] = source
            changed = True
if changed:
    with open(path, "w") as f:
        json.dump(project, f, indent=2)
        f.write("\n")
PY
(
  cd "$project_dir"
  if ! rg -q '"name": "AllowProfileLookup"' agentcore/agentcore.json; then
    "$ac" add policy --name AllowProfileLookup --engine BankPolicyEngine --source "$work_dir/profile.dw" --validation-mode FAIL_ON_ANY_FINDINGS --enforcement-mode ACTIVE
  fi
  if ! rg -q '"name": "TransferAmountLimit"' agentcore/agentcore.json; then
    "$ac" add policy --name TransferAmountLimit --engine BankPolicyEngine --source "$work_dir/transfer-limit.dw" --validation-mode FAIL_ON_ANY_FINDINGS --enforcement-mode ACTIVE
  fi
  "$ac" deploy --yes
)
# Gateway IAM credential providers obtain a workload token before dispatching
# to Lambda. The CLI-created role needs this explicit least-privilege grant.
gateway_id="${BARN##*/}"
gateway_role_arn="$(aws bedrock-agentcore-control get-gateway --region "$region" --gateway-identifier "$gateway_id" --query 'roleArn' --output text)"
gateway_role_name="${gateway_role_arn##*/}"
gateway_workload_identity_arn="$(aws bedrock-agentcore-control get-gateway --region "$region" --gateway-identifier "$gateway_id" --query 'workloadIdentityDetails.workloadIdentityArn' --output text)"
gateway_workload_identity_directory_arn="${gateway_workload_identity_arn%/workload-identity/*}"
workload_access_policy="$(WORKLOAD_IDENTITY_ARN="$gateway_workload_identity_arn" WORKLOAD_IDENTITY_DIRECTORY_ARN="$gateway_workload_identity_directory_arn" python3 -c '
import json, os
print(json.dumps({
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": "bedrock-agentcore:GetWorkloadAccessToken",
        "Resource": [
            os.environ["WORKLOAD_IDENTITY_DIRECTORY_ARN"],
            os.environ["WORKLOAD_IDENTITY_ARN"],
        ],
    }],
}))
')"
aws iam put-role-policy --role-name "$gateway_role_name" --policy-name AgentCoreGatewayWorkloadAccess --policy-document "$workload_access_policy"
status="$(cd "$project_dir" && "$ac" status --json)"
eval "$(STATUS="$status" python3 -c '
import json, os
r = json.loads(os.environ["STATUS"])["deployedState"]["targets"]["default"]["resources"]
g = r.get("mcp", {}).get("gateways", r.get("gateways", {}))["BankGateway"]
print("RARN=" + repr(r["runtimes"]["TemporalPolicyAgent"]["runtimeArn"]))
print("BARN=" + repr(g["gatewayArn"]))
print("BURL=" + repr(g["gatewayUrl"]))
')"
printf 'AWS_REGION=%s\nTEMPORAL_RUNTIME_ARN=%s\nBANK_GATEWAY_ARN=%s\nBANK_GATEWAY_URL=%s\n' "$region" "$RARN" "$BARN" "$BURL" > "$work_dir/deployment.env"
