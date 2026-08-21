import sys
import unittest
from pathlib import Path

DEMO_ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(DEMO_ROOT / "lambda"))
import bank  # noqa: E402


class BankTargetTests(unittest.TestCase):
    def test_profile_response_contains_the_authoritative_account(self):
        response = bank.get_client_profile({"profile_id": "xyz"})
        self.assertEqual(response["profile_id"], "xyz")
        self.assertEqual(response["account_number"], "abc")
        self.assertEqual(response["name"], "Avery Example")

    def test_unknown_profile_has_no_account_output(self):
        response = bank.get_client_profile({"profile_id": "does-not-exist"})
        self.assertEqual(response, {"status": "error", "error_code": "PROFILE_NOT_FOUND"})

    def test_transfer_target_only_returns_a_simulation_result(self):
        response = bank.transfer_funds(
            {
                "profile_id": "xyz",
                "to_account": "ghi",
                "amount": 5000,
            }
        )
        self.assertEqual(response["status"], "simulated")
        self.assertTrue(response["transfer_id"].startswith("sim_transfer_"))
        self.assertEqual(set(response), {"transfer_id", "status"})

    def test_target_tool_schemas_are_present(self):
        self.assertTrue((DEMO_ROOT / "profile_tools.json").is_file())
        self.assertTrue((DEMO_ROOT / "transfer_tools.json").is_file())


class PolicyArtifactTests(unittest.TestCase):
    def test_policy_compares_profile_response_outputs_to_transfer_input(self):
        policy = (DEMO_ROOT / "policies" / "transfer_amount_limit.template.dw").read_text()
        self.assertIn('formerly within 15m AgentCore::Action::"BankProfile___get_client_profile"::response', policy)
        self.assertIn("output.account_number: context.input.to_account", policy)
        self.assertIn("output.profile_id:     context.input.profile_id", policy)
        self.assertIn("eventResource:         resource", policy)

    def test_agentcore_templates_contain_one_statement_each(self):
        policy_dir = DEMO_ROOT / "policies"
        transfer = (policy_dir / "transfer_amount_limit.template.dw").read_text()
        profile = (policy_dir / "allow_profile_lookup.template.dw").read_text()
        self.assertEqual(transfer.count("permit ("), 1)
        self.assertEqual(profile.count("permit ("), 1)

    def test_local_policy_schema_uses_the_deployed_profile_action(self):
        schema = (DEMO_ROOT / "policies" / "bank.cedarschema").read_text()
        self.assertIn('action "BankProfile___get_client_profile"', schema)
        self.assertNotIn('action "BankTransfer___get_client_profile"', schema)

    def test_invocation_uses_the_runtime_and_supplies_a_system_prompt(self):
        source = (DEMO_ROOT / "scripts" / "demo.py").read_text()
        self.assertIn("invoke_agent_runtime", source)
        self.assertIn('"system_prompt": SYSTEM_PROMPT', source)

    def test_deployment_uses_one_mcp_gateway_and_has_a_raw_discovery_probe(self):
        deploy = (DEMO_ROOT / "scripts" / "deploy.sh").read_text()
        probe = (DEMO_ROOT / "scripts" / "list_tools.py").read_text()
        self.assertIn('--name BankGateway --protocol-type MCP', deploy)
        self.assertIn('--name BankProfile --gateway BankGateway', deploy)
        self.assertIn('--name BankTransfer --gateway BankGateway', deploy)
        self.assertIn('BURL="$BURL"', deploy)
        self.assertNotIn('BURL="$BURL/mcp"', deploy)
        self.assertIn('if not url.endswith("/mcp"):', probe)
        self.assertIn('"method": "tools/list"', probe)
