"""Gemini model configuration backed by AgentCore Identity."""

import os

from bedrock_agentcore.identity.auth import requires_api_key
from strands.models.gemini import GeminiModel

IDENTITY_PROVIDER_NAME = "temporal-demo-gemini-key"
IDENTITY_ENV_VAR = "AGENTCORE_CREDENTIAL_TEMPORAL_DEMO_GEMINI_KEY"


@requires_api_key(provider_name=IDENTITY_PROVIDER_NAME)
def agentcore_identity_api_key_provider(api_key: str) -> str:
    return api_key


def get_api_key() -> str:
    if os.getenv("LOCAL_DEV") == "1":
        api_key = os.getenv(IDENTITY_ENV_VAR)
        if not api_key:
            raise RuntimeError(f"{IDENTITY_ENV_VAR} not found in local development")
        return api_key
    return agentcore_identity_api_key_provider()


def load_model() -> GeminiModel:
    return GeminiModel(
        client_args={"api_key": get_api_key()},
        model_id="gemini-3.5-flash-lite",
    )
