"""AWS Lambda handler for the simulated transfer Gateway target."""

import logging

from bank import transfer_funds


def lambda_handler(event, context):
    logging.getLogger().info(
        "AgentCore Gateway invocation gateway_id=%s target_id=%s tool_name=%s",
        getattr(context, "bedrockAgentCoreGatewayId", None),
        getattr(context, "bedrockAgentCoreTargetId", None),
        getattr(context, "bedrockAgentCoreToolName", None),
    )
    return transfer_funds(event, context)
