#!/usr/bin/env bash
# Tears down all resources created by scripts/deploy.sh, including the Gemini
# API-key credential provider. Do not use a shared GEMINI_CREDENTIAL_NAME.
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
credential_name="${GEMINI_CREDENTIAL_NAME:-payment-demo-gemini-key}"

[[ -n "$region" ]] || { echo "Set AWS_REGION or configure an AWS default region." >&2; exit 2; }
command -v aws >/dev/null || { echo "Install AWS CLI v2." >&2; exit 2; }

# The current AgentCore CLI deploys this project through its generated CDK
# stack, but does not offer a `destroy` command. Delete that stack directly
# before deleting the Lambda stack it targets.
agentcore_state="$project_dir/agentcore/.cli/deployed-state.json"
if [[ -f "$agentcore_state" ]]; then
  agentcore_stack_name="$(DEPLOYED_STATE="$agentcore_state" python3 -c '
import json, os
with open(os.environ["DEPLOYED_STATE"]) as f:
    state = json.load(f)
resources = state.get("targets", {}).get("default", {}).get("resources", {})
name = resources.get("stackName", "")
if not name:
    raise SystemExit("AgentCore stack name not found in deployed state")
print(name)
')"
  if aws cloudformation describe-stacks --region "$region" --stack-name "$agentcore_stack_name" >/dev/null 2>&1; then
    aws cloudformation delete-stack --region "$region" --stack-name "$agentcore_stack_name"
    aws cloudformation wait stack-delete-complete --region "$region" --stack-name "$agentcore_stack_name"
  else
    echo "AgentCore stack $agentcore_stack_name does not exist; skipping."
  fi
else
  echo "No AgentCore deployed state found; skipping AgentCore stack deletion."
fi

# CloudFormation delete is safe to rerun once the stack is already gone.
if aws cloudformation describe-stacks --region "$region" --stack-name "$stack_name" >/dev/null 2>&1; then
  aws cloudformation delete-stack --region "$region" --stack-name "$stack_name"
  aws cloudformation wait stack-delete-complete --region "$region" --stack-name "$stack_name"
else
  echo "CloudFormation stack $stack_name does not exist; skipping."
fi

# The provider contains the raw Gemini API key. This script assumes its name is
# dedicated to this harness; use a different name for any shared provider.
credential_exists="$(CREDENTIAL_NAME="$credential_name" aws bedrock-agentcore-control list-api-key-credential-providers --region "$region" --output json \
  | CREDENTIAL_NAME="$credential_name" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
n = os.environ["CREDENTIAL_NAME"]
providers = d.get("credentialProviders", []) + d.get("apiKeyCredentialProviders", []) + d.get("items", [])
print("true" if any(p.get("name") == n for p in providers) else "false")
')"
if [[ "$credential_exists" == "true" ]]; then
  aws bedrock-agentcore-control delete-api-key-credential-provider \
    --region "$region" --name "$credential_name"
else
  echo "Credential provider $credential_name does not exist; skipping."
fi

# This directory is deployment-generated state. Removing it ensures the next
# deploy creates a new AgentCore project instead of reusing deleted resources.
rm -rf "$work_dir"
echo "Destroyed AgentCore resources, Lambda stack, and credential provider."
