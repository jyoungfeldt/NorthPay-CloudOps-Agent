"""
NorthPay CloudOps Agent — Cost Explorer tool Lambda
Queries AWS Cost Explorer for anomalies and cost breakdowns.
"""

import json
import os
import time
import uuid
import boto3
from datetime import datetime, timedelta, timezone

ce = boto3.client("ce")
dynamodb = boto3.resource("dynamodb")

AUDIT_TABLE = os.environ["AUDIT_TABLE"]
table = dynamodb.Table(AUDIT_TABLE)


def handler(event: dict, context) -> dict:
    """
    Query AWS Cost Explorer.

    Input event:
      query_type: "anomalies" | "breakdown" | "forecast"
      days_back:  int (default 14)
      session_id: str

    Returns:
      results: dict with cost data
    """
    session_id = event.get("session_id", str(uuid.uuid4()))
    query_type = event.get("query_type", "anomalies")
    days_back = int(event.get("days_back", 14))

    _log_invocation(session_id, "cost_explorer_query", event)

    end_date = datetime.now(timezone.utc).date()
    start_date = end_date - timedelta(days=days_back)

    if query_type == "anomalies":
        result = _get_anomalies(str(start_date), str(end_date))
    elif query_type == "breakdown":
        result = _get_cost_breakdown(str(start_date), str(end_date))
    else:
        result = _get_cost_breakdown(str(start_date), str(end_date))

    return {
        "results": result,
        "query_type": query_type,
        "period": {"start": str(start_date), "end": str(end_date)},
        "session_id": session_id,
    }


def _get_anomalies(start_date: str, end_date: str) -> dict:
    response = ce.get_anomalies(
        DateInterval={"StartDate": start_date, "EndDate": end_date},
        TotalImpact={"NumericOperator": "GREATER_THAN", "StartValue": 10.0},
    )
    anomalies = [
        {
            "anomaly_id": a["AnomalyId"],
            "service": a.get("DimensionValue", "unknown"),
            "impact_total": a["Impact"].get("TotalImpact", 0),
            "impact_percentage": a["Impact"].get("TotalImpactPercentage", 0),
            "start_date": a["AnomalyStartDate"],
            "end_date": a.get("AnomalyEndDate", "ongoing"),
        }
        for a in response.get("Anomalies", [])
    ]
    return {"anomalies": anomalies, "count": len(anomalies)}


def _get_cost_breakdown(start_date: str, end_date: str) -> dict:
    response = ce.get_cost_and_usage(
        TimePeriod={"Start": start_date, "End": end_date},
        Granularity="DAILY",
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        Metrics=["UnblendedCost"],
    )
    results = []
    for period in response.get("ResultsByTime", []):
        for group in period.get("Groups", []):
            cost = float(group["Metrics"]["UnblendedCost"]["Amount"])
            if cost > 0.01:  # filter noise
                results.append({
                    "date": period["TimePeriod"]["Start"],
                    "service": group["Keys"][0],
                    "cost_usd": round(cost, 4),
                })
    # Sort by cost descending
    results.sort(key=lambda x: x["cost_usd"], reverse=True)
    return {"breakdown": results[:50]}  # top 50 line items


def _log_invocation(session_id: str, tool_name: str, inputs: dict) -> None:
    ttl = int(time.time()) + (90 * 86400)
    table.put_item(Item={
        "pk": f"SESSION#{session_id}",
        "sk": f"TOOL#{datetime.now(timezone.utc).isoformat()}#{tool_name}",
        "session_id": session_id,
        "tool_name": tool_name,
        "inputs": json.dumps(inputs, default=str),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "ttl": ttl,
    })
