# AgentCore Payment Demos

This repository contains two self-contained AgentCore authorization and architecture demos. Both demos use simulated targets—there is no real bank, wallet, persistence, or real money movement involved. The primary goal is to demonstrate secure integration patterns using Amazon Bedrock AgentCore.

## Demos Summary

*   **[Basic Payment Demo (Cedar with Harness)](cedar-with-harness/README.md)**: Demonstrates a straightforward, managed `Harness` integration with a single Gateway tool and static, stateless Cedar policy enforcement (e.g., amount limits).
*   **[Temporal Policy Demo (Dogwood with Runtime)](temporal-dogwood-with-runtime/README.md)**: Demonstrates advanced, stateful authorization using a standalone AgentCore Runtime and Dogwood temporal policies to enforce operation order and dependencies across multiple agent tool calls (e.g., a transfer requires a recent profile lookup).

---

## 1. Basic Payment Demo (`cedar-with-harness`)
**Path:** `cedar-with-harness/`

This demo implements a minimal Cloud architecture using the fully managed AgentCore Harness, backed by Gemini 3.5 Flash Lite. 

**Architecture Flow:**
`IAM caller -> AgentCore Harness (Gemini) -> AgentCore Gateway -> Cedar ENFORCE -> Payment Lambda`

**Key Features:**
*   **Single Tool Access:** The Harness exposes only one tool: `PaymentTools___make_payment`.
*   **Cedar Policy Enforcement:** Gateway authorization relies on Cedar in `ENFORCE` mode. The policy employs a default-deny stance, exclusively permitting `make_payment` when the `amount <= 1000`.
*   **Prompt Injection Protection:** Even if the agent hallucinates or is maliciously prompted to exceed limits or call unauthorized tools, the Cedar policy safely rejects the request at the Gateway layer, before Lambda invocation.
*   **Least-Privilege Setup:** Includes sample IAM policies (`iam/caller-harness-only.json`) that explicitly allow Harness invocation while denying direct Gateway execution by end-users.

**Getting Started:**
Start with its [README](cedar-with-harness/README.md).

## 2. Temporal Policy Demo (`temporal-dogwood-with-runtime`)
**Path:** `temporal-dogwood-with-runtime/`

This demo tackles a more complex authorization challenge: proving that an agent didn't just invent valid-looking data to bypass security. It introduces stateful time-based policies using Dogwood.

**Architecture Flow:**
`AgentCore Runtime -> MCP Gateway -> Dogwood ENFORCE -> Profile & Transfer Lambdas`

**Key Features:**
*   **Custom AgentCore Runtime:** Replaces the managed Harness with a custom Python runtime that mounts MCP (Model Context Protocol) tools and maintains basic conversation state.
*   **Multi-step Stateful Authorization:** Enforces strict execution order using Dogwood temporal policies. A `BankTransfer___transfer_funds` action is *only* allowed if the agent can prove a `BankProfile___get_client_profile` response occurred within the last 15 minutes, returning the *exact* target account number.
*   **Rate & Cap Limiting:** The temporal policy also tracks rolling budgets, enforcing a maximum transfer limit of 5,000 units per profile within any 8-hour window.
*   **Caller Isolation:** History events are pinned to the specific caller principal, ensuring distinct state boundaries between different users.
*   **Local Policy Replay:** The demo supports full local policy testing and trace replay using the Dogwood CLI, enabling fast feedback loops without AWS deployments.

**Getting Started:**
Start with its [README](temporal-dogwood-with-runtime/README.md).
