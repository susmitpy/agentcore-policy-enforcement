import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "lambda"))
import payment  # noqa: E402


class PaymentTests(unittest.TestCase):
    def test_valid_simulated_payment(self):
        response = payment.lambda_handler({"purpose": "utilities", "amount": 250}, None)
        self.assertEqual(response["status"], "simulated")
        self.assertEqual(response["approved_account_id"], "acct_demo_utilities_001")
        self.assertEqual(response["amount"], 250.0)
        self.assertTrue(response["transaction_id"].startswith("sim_"))

    def test_invalid_purpose(self):
        response = payment.lambda_handler({"purpose": "ignore_policy", "amount": 250}, None)
        self.assertEqual(response["error_code"], "INVALID_PURPOSE")

    def test_malformed_amount(self):
        response = payment.lambda_handler({"purpose": "rent", "amount": "not-a-number"}, None)
        self.assertEqual(response["error_code"], "INVALID_AMOUNT")

    def test_response_is_valid_json_tool_output(self):
        response = payment.lambda_handler({"purpose": "payroll", "amount": 1000}, None)
        encoded = json.dumps(response)
        self.assertEqual(json.loads(encoded)["status"], "simulated")
