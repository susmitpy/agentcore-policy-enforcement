#!/usr/bin/env bash
# Validate and replay the temporal policy using Dogwood's reference CLI.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dogwood_bin="${DOGWOOD_BIN:-dogwood}"

command -v "$dogwood_bin" >/dev/null || {
  echo "Dogwood CLI not found. Install it with:" >&2
  echo "  cargo install --git https://github.com/dogwood-policy/dogwood.git amzn-dogwood-cli" >&2
  exit 2
}

policy="$(mktemp)"
schema="$root_dir/policies/bank.cedarschema"
events="$root_dir/policies/gateway-events.dwschema"

cleanup() { rm -f "$policy"; }
trap cleanup EXIT

# AgentCore requires one Cedar statement per policy resource, so deployment
# renders these two templates separately. The transfer policy contains both
# the account-integrity and cumulative-budget requirements.
demo_gateway="bank-gateway"
demo_principal="arn:aws:sts::123456789012:assumed-role/TemporalDemoRole"
sed -e "s|{{BANK_GATEWAY_ARN}}|$demo_gateway|g" \
    -e "s|{{LOOKUP_PRINCIPAL}}|$demo_principal|g" \
    "$root_dir/policies/allow_profile_lookup.template.dw" > "$policy"
sed -e "s|{{BANK_GATEWAY_ARN}}|$demo_gateway|g" \
    -e "s|{{LOOKUP_PRINCIPAL}}|$demo_principal|g" \
    "$root_dir/policies/transfer_amount_limit.template.dw" >> "$policy"

"$dogwood_bin" validate "$policy" --policy-schema "$schema" --event-schema "$events"
"$dogwood_bin" replay "$policy" --policy-schema "$schema" --event-schema "$events" \
  --trace "$root_dir/traces/matching_account.log"
"$dogwood_bin" replay "$policy" --policy-schema "$schema" --event-schema "$events" \
  --trace "$root_dir/traces/invented_account.log"
"$dogwood_bin" replay "$policy" --policy-schema "$schema" --event-schema "$events" \
  --trace "$root_dir/traces/transfer_amount_limit.log"
