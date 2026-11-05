"""
NorthPay CloudOps Agent — Strands Agents SDK implementation
Wires together Bedrock, tools, Knowledge Base, and Guardrails.
"""

import json
import os
import uuid
import boto3
from strands import Agent, tool
from strands.models import BedrockModel

# ── AWS clients ───────────────────────────────────────────────────────────────

_lambda = boto3.client("lambda")
_sfn = boto3.client("stepfunctions")

# ── Configuration (populated from environment / Terraform outputs) ────────────

MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "anthropic.claude-sonnet-4-6")
KNOWLEDGE_BASE_ID = os.environ["KNOWLEDGE_BASE_ID"]
GUARDRAIL_ID = os.environ["GUARDRAIL_ID"]
GUARDRAIL_VERSION = os.environ.get("GUARDRAIL_VERSION", "1")
SFN_ARN = os.environ["SFN_ARN"]

LAMBDA_ARNS = {
    "security_hub": os.environ["LAMBDA_ARN_SECURITY_HUB"],
    "cost_explorer": os.environ["LAMBDA_ARN_COST_EXPLORER"],
    "remediate":     os.environ["LAMBDA_ARN_REMEDIATE"],
}

# ── Tools ─────────────────────────────────────────────────────────────────────


@tool
def query_security_hub(
    severity: str = "HIGH,CRITICAL",
    resource_type: str = "",
    max_results: int = 20,
    session_id: str = "",
) -> dict:
    """
    Query AWS Security Hub for active findings.

    Args:
        severity: Comma-separated severity labels to filter on (CRITICAL, HIGH, MEDIUM, LOW)
        resource_type: Optional AWS resource type filter (e.g. AwsS3Bucket)
        max_results: Maximum number of findings to return (max 100)
        session_id: Correlation ID for audit logging

    Returns:
        Dict with 'findings' list and 'count'
    """
    filters = {
        "RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}],
        "WorkflowStatus": [{"Value": "NEW", "Comparison": "EQUALS"}],
        "SeverityLabel": [
            {"Value": s.strip(), "Comparison": "EQUALS"}
            for s in severity.split(",")
        ],
    }
    if resource_type:
        filters["ResourceType"] = [{"Value": resource_type, "Comparison": "PREFIX"}]

    response = _lambda.invoke(
        FunctionName=LAMBDA_ARNS["security_hub"],
        Payload=json.dumps({
            "filters": filters,
            "max_results": max_results,
            "session_id": session_id or str(uuid.uuid4()),
        }),
    )
    return json.loads(response["Payload"].read())


@tool
def query_cost_explorer(
    query_type: str = "anomalies",
    days_back: int = 14,
    session_id: str = "",
) -> dict:
    """
    Query AWS Cost Explorer for cost anomalies or service breakdowns.

    Args:
        query_type: 'anomalies' to find cost spikes, 'breakdown' for service cost detail
        days_back: Number of days to look back (default 14)
        session_id: Correlation ID for audit logging

    Returns:
        Dict with cost results
    """
    response = _lambda.invoke(
        FunctionName=LAMBDA_ARNS["cost_explorer"],
        Payload=json.dumps({
            "query_type": query_type,
            "days_back": days_back,
            "session_id": session_id or str(uuid.uuid4()),
        }),
    )
    return json.loads(response["Payload"].read())


@tool
def propose_and_request_approval(
    finding: dict,
    proposed_fix: str,
    session_id: str = "",
) -> dict:
    """
    Submit a proposed remediation fix for human approval via Step Functions.
    The fix will NOT be applied until a human approves it via email/Slack link.

    Args:
        finding: The Security Hub finding dict returned by query_security_hub
        proposed_fix: Plain-English description of the change to be made
        session_id: Correlation ID

    Returns:
        Dict with execution_arn and status 'PENDING_APPROVAL'
    """
    execution_id = str(uuid.uuid4())
    response = _sfn.start_execution(
        stateMachineArn=SFN_ARN,
        name=f"approval-{execution_id}",
        input=json.dumps({
            "execution_id": execution_id,
            "session_id": session_id or str(uuid.uuid4()),
            "finding": finding,
            "proposed_fix": proposed_fix,
        }),
    )
    return {
        "status": "PENDING_APPROVAL",
        "execution_id": execution_id,
        "execution_arn": response["executionArn"],
        "message": "An approval request has been sent. The fix will be applied only after a human approves it.",
    }


# ── System prompt ─────────────────────────────────────────────────────────────

SYSTEM_PROMPT = """You are the NorthPay CloudOps Agent, a helpful and careful AI assistant
for NorthPay's cloud operations team.

Your responsibilities:
1. Find security and cost issues in NorthPay's AWS environment
2. Explain each issue clearly, citing the relevant NorthPay runbook when one exists
3. Propose a specific, actionable fix
4. Submit fixes for human approval — NEVER apply a change without approval

Rules you must follow:
- Always check the knowledge base for a relevant runbook before proposing a fix
- Use plain English. Your audience is both engineers and auditors.
- Quote the runbook ID (e.g. RB-S3-001) when you cite one
- For PCI-relevant findings, mention the DSS control number
- When proposing a fix, be specific about what will change and what won't
- NEVER apply remediation without going through propose_and_request_approval first
- If you're unsure, ask for clarification rather than guessing

You have access to:
- query_security_hub: read AWS Security Hub findings
- query_cost_explorer: read AWS cost and anomaly data
- propose_and_request_approval: submit a fix for human approval
- Knowledge Base: NorthPay runbooks and PCI-DSS control mappings
"""


# ── Build the agent ───────────────────────────────────────────────────────────

def build_agent() -> Agent:
    model = BedrockModel(
        model_id=MODEL_ID,
        guardrail_id=GUARDRAIL_ID,
        guardrail_version=GUARDRAIL_VERSION,
    )

    agent = Agent(
        model=model,
        system_prompt=SYSTEM_PROMPT,
        tools=[query_security_hub, query_cost_explorer, propose_and_request_approval],
        knowledge_bases=[{
            "knowledgeBaseId": KNOWLEDGE_BASE_ID,
            "retrievalConfiguration": {
                "vectorSearchConfiguration": {
                    "numberOfResults": 5,
                    "overrideSearchType": "HYBRID",
                }
            },
        }],
    )
    return agent
