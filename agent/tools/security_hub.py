"""
NorthPay CloudOps Agent — Security Hub tool Lambda
Queries AWS Security Hub for findings and logs each invocation to DynamoDB.
"""

import json
import os
import time
import uuid
import boto3
from datetime import datetime, timezone

securityhub = boto3.client("securityhub")
dynamodb = boto3.resource("dynamodb")

AUDIT_TABLE = os.environ["AUDIT_TABLE"]
table = dynamodb.Table(AUDIT_TABLE)


def handler(event: dict, context) -> dict:
    """
    Query Security Hub findings.

    Input event:
      filters     (optional) dict of Security Hub filters
      max_results (optional) int, default 20
      session_id  (optional) str for correlation

    Returns:
      findings: list of simplified finding objects
      count: int
    """
    session_id = event.get("session_id", str(uuid.uuid4()))
    max_results = min(int(event.get("max_results", 20)), 100)
    filters = event.get("filters", {
        "RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}],
        "WorkflowStatus": [{"Value": "NEW", "Comparison": "EQUALS"}],
        "SeverityLabel": [
            {"Value": "CRITICAL", "Comparison": "EQUALS"},
            {"Value": "HIGH", "Comparison": "EQUALS"},
        ],
    })

    _log_invocation(session_id, "security_hub_query", {"filters": filters})

    response = securityhub.get_findings(
        Filters=filters,
        MaxResults=max_results,
        SortCriteria=[{"Field": "SeverityLabel", "SortOrder": "desc"}],
    )

    findings = [
        {
            "id": f["Id"],
            "title": f["Title"],
            "description": f.get("Description", ""),
            "severity": f["Severity"]["Label"],
            "resource_type": f["Resources"][0]["Type"] if f.get("Resources") else "unknown",
            "resource_id": f["Resources"][0]["Id"] if f.get("Resources") else "unknown",
            "compliance_status": f.get("Compliance", {}).get("Status", "UNKNOWN"),
            "remediation": f.get("Remediation", {}).get("Recommendation", {}).get("Text", ""),
        }
        for f in response.get("Findings", [])
    ]

    return {
        "findings": findings,
        "count": len(findings),
        "session_id": session_id,
    }


def _log_invocation(session_id: str, tool_name: str, inputs: dict) -> None:
    ttl = int(time.time()) + (90 * 86400)  # 90 days
    table.put_item(Item={
        "pk": f"SESSION#{session_id}",
        "sk": f"TOOL#{datetime.now(timezone.utc).isoformat()}#{tool_name}",
        "session_id": session_id,
        "tool_name": tool_name,
        "inputs": json.dumps(inputs),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "ttl": ttl,
    })
