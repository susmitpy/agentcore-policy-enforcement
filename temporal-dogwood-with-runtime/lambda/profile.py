"""AWS Lambda handler for the simulated profile Gateway target."""

import logging

from bank import get_client_profile


def lambda_handler(event, context):
    logging.getLogger().info(
        "AgentCore Gateway invocation gateway_id=%s target_id=%s tool_name=%s",
        getattr(context, "bedrockAgentCoreGatewayId", None),
        getattr(context, "bedrockAgentCoreTargetId", None),
        getattr(context, "bedrockAgentCoreToolName", None),
    )
    return get_client_profile(event, context)
