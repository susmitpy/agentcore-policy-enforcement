"""Simulated, allowlisted payment tool for an AgentCore Gateway Lambda target."""

import uuid
from datetime import UTC, datetime
from decimal import Decimal, InvalidOperation
from typing import Any

APPROVED_PURPOSES = {
    "rent": "acct_demo_rent_001",
    "utilities": "acct_demo_utilities_001",
    "payroll": "acct_demo_payroll_001",
    "vendor_invoice": "acct_demo_vendor_001",
}


def _error(code: str, message: str) -> dict[str, str]:
    return {"status": "error", "error_code": code, "message": message}


def validate_payment(event: Any) -> tuple[str, Decimal] | dict[str, str]:
    """Validate the direct event map supplied by an AgentCore Gateway Lambda target."""
    if not isinstance(event, dict):
        return _error("INVALID_INPUT", "Tool input must be a JSON object.")

    purpose = event.get("purpose")
    if not isinstance(purpose, str) or purpose not in APPROVED_PURPOSES:
        return _error(
            "INVALID_PURPOSE",
            "purpose must be one of: " + ", ".join(sorted(APPROVED_PURPOSES)),
        )

    amount = event.get("amount")
    if isinstance(amount, bool) or not isinstance(amount, (int, float, str)):
        return _error("INVALID_AMOUNT", "amount must be a positive finite number.")
    try:
        parsed = Decimal(str(amount))
    except (InvalidOperation, ValueError):
        return _error("INVALID_AMOUNT", "amount must be a positive finite number.")
    if not parsed.is_finite() or parsed <= 0:
        return _error("INVALID_AMOUNT", "amount must be a positive finite number.")
    return purpose, parsed


def lambda_handler(event: Any, _context: Any) -> dict[str, Any]:
    """Return JSON directly; AgentCore Gateway passes schema properties as `event`."""
    valid = validate_payment(event)
    if isinstance(valid, dict):
        return valid

    purpose, amount = valid
    return {
        "status": "simulated",
        "transaction_id": f"sim_{uuid.uuid4().hex}",
        "approved_account_id": APPROVED_PURPOSES[purpose],
        "amount": float(amount),
        "currency": "INR",
        "timestamp": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "message": "Simulated payment only; no funds moved.",
    }
