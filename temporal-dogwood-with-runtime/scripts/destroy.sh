#!/usr/bin/env bash
# Deletes only the AgentCore project state and Lambda stack created by deploy.sh.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$root_dir/.env" ]]; then
  set -a
  source "$root_dir/.env"
  set +a
fi

work_dir="$root_dir/.agentcore-work"
project_dir="$work_dir/TemporalPolicyDemo"
stack_name="${STACK_NAME:-agentcore-temporal-demo}"
region="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
credential_name="${GEMINI_CREDENTIAL_NAME:-temporal-demo-gemini-key}"

[[ -n "$region" ]] || { echo "Set AWS_REGION or configure an AWS default region." >&2; exit 2; }
command -v aws >/dev/null || { echo "Install AWS CLI v2." >&2; exit 2; }

# The AgentCore CLI deploys through a generated CloudFormation stack. Delete it
# before the Lambda stack because its Gateway targets reference both functions.
agentcore_state="$project_dir/agentcore/.cli/deployed-state.json"
if [[ -f "$agentcore_state" ]]; then
  agentcore_stack_name="$(DEPLOYED_STATE="$agentcore_state" python3 -c '
import json, os
with open(os.environ["DEPLOYED_STATE"]) as f: state = json.load(f)
name = state.get("targets", {}).get("default", {}).get("resources", {}).get("stackName", "")
print(name)
')"
  if [[ -n "$agentcore_stack_name" ]] && aws cloudformation describe-stacks --region "$region" --stack-name "$agentcore_stack_name" >/dev/null 2>&1; then
    aws cloudformation delete-stack --region "$region" --stack-name "$agentcore_stack_name"
    aws cloudformation wait stack-delete-complete --region "$region" --stack-name "$agentcore_stack_name"
  elif [[ -z "$agentcore_stack_name" ]]; then
    echo "No AgentCore stack name in partial deployment state; skipping AgentCore stack deletion."
  fi
else
  echo "No AgentCore deployed state found; skipping AgentCore stack deletion."
fi

if aws cloudformation describe-stacks --region "$region" --stack-name "$stack_name" >/dev/null 2>&1; then
  aws cloudformation delete-stack --region "$region" --stack-name "$stack_name"
  aws cloudformation wait stack-delete-complete --region "$region" --stack-name "$stack_name"
fi

# This credential provider holds the raw Gemini API key. Keep the name dedicated
# to this demo because teardown deletes it.
credential_exists="$(CREDENTIAL_NAME="$credential_name" aws bedrock-agentcore-control list-api-key-credential-providers --region "$region" --output json \
  | CREDENTIAL_NAME="$credential_name" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
n = os.environ["CREDENTIAL_NAME"]
providers = d.get("credentialProviders", []) + d.get("apiKeyCredentialProviders", []) + d.get("items", [])
print("true" if any(p.get("name") == n for p in providers) else "false")
')"
if [[ "$credential_exists" == "true" ]]; then
  aws bedrock-agentcore-control delete-api-key-credential-provider --region "$region" --name "$credential_name"
fi

rm -rf "$work_dir"
echo "Destroyed AgentCore Runtime/Gateway resources, Lambda stack, credential provider, and generated local state."
