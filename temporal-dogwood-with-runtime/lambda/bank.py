"""Simulated Gateway targets for the temporal output-to-input policy demo."""

import uuid
from typing import Any


PROFILES = {
    "xyz": {
        "profile_id": "xyz",
        "account_number": "abc",
        "name": "Avery Example",
    }
}


def get_client_profile(event: Any, _context: Any = None) -> dict[str, str]:
    """Return the authoritative simulated account for a known profile."""
    if not isinstance(event, dict) or not isinstance(event.get("profile_id"), str):
        return {"status": "error", "error_code": "INVALID_PROFILE_ID"}

    profile = PROFILES.get(event["profile_id"])
    if profile is None:
        return {"status": "error", "error_code": "PROFILE_NOT_FOUND"}
    return dict(profile)


def transfer_funds(event: Any, _context: Any = None) -> dict[str, str]:
    """Create a simulated transfer; authorization belongs before this target."""
    del event
    return {"transfer_id": f"sim_transfer_{uuid.uuid4().hex}", "status": "simulated"}
