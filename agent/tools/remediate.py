"""
NorthPay CloudOps Agent — Remediation Lambda
Applies approved fixes. Only called after Step Functions approval.
Logs every action to DynamoDB.
"""

import json
import os
import time
import uuid
import boto3
from datetime import datetime, timezone

dynamodb = boto3.resource("dynamodb")
s3 = boto3.client("s3")

AUDIT_TABLE = os.environ["AUDIT_TABLE"]
table = dynamodb.Table(AUDIT_TABLE)

# Supported remediation actions
SUPPORTED_ACTIONS = {
    "s3_block_public_access",
    "s3_enable_encryption",
}


def handler(event: dict, context) -> dict:
    """
    Apply an approved remediation.

    Input event (from Step Functions):
      finding:      dict with resource_type, resource_id, etc.
      proposed_fix: str describing the fix
      approved_by:  str (email / Slack user)

    Returns:
      status:  "success" | "skipped" | "error"
      message: str
      action:  str
    """
    finding = event.get("finding", {})
    proposed_fix = event.get("proposed_fix", "")
    approved_by = event.get("approved_by", "unknown")
    execution_id = event.get("execution_id", str(uuid.uuid4()))

    action = _infer_action(finding, proposed_fix)

    if action not in SUPPORTED_ACTIONS:
        result = {
            "status": "skipped",
            "message": f"Action '{action}' is not in the supported remediation list. Manual action required.",
            "action": action,
        }
    else:
        result = _apply_action(action, finding)

    # Always log to DynamoDB — even skipped/error actions
    _log_remediation(execution_id, finding, action, result, approved_by)

    return result


def _infer_action(finding: dict, proposed_fix: str) -> str:
    """Map a finding + proposed fix text to a supported action ID."""
    resource_type = finding.get("resource_type", "").lower()
    fix_lower = proposed_fix.lower()

    if "s3" in resource_type:
        if "public access" in fix_lower or "blockpublicaccess" in fix_lower:
            return "s3_block_public_access"
        if "encrypt" in fix_lower:
            return "s3_enable_encryption"
    return "unknown"


def _apply_action(action: str, finding: dict) -> dict:
    resource_id = finding.get("resource_id", "")
    # resource_id for S3 is "arn:aws:s3:::bucket-name"
    bucket_name = resource_id.split(":::")[-1]

    try:
        if action == "s3_block_public_access":
            s3.put_public_access_block(
                Bucket=bucket_name,
                PublicAccessBlockConfiguration={
                    "BlockPublicAcls": True,
                    "IgnorePublicAcls": True,
                    "BlockPublicPolicy": True,
                    "RestrictPublicBuckets": True,
                },
            )
            return {
                "status": "success",
                "message": f"Blocked all public access on s3://{bucket_name}",
                "action": action,
                "resource": bucket_name,
            }

        if action == "s3_enable_encryption":
            s3.put_bucket_encryption(
                Bucket=bucket_name,
                ServerSideEncryptionConfiguration={
                    "Rules": [{
                        "ApplyServerSideEncryptionByDefault": {
                            "SSEAlgorithm": "aws:kms"
                        },
                        "BucketKeyEnabled": True,
                    }]
                },
            )
            return {
                "status": "success",
                "message": f"Enabled KMS encryption on s3://{bucket_name}",
                "action": action,
                "resource": bucket_name,
            }

    except Exception as exc:
        return {
            "status": "error",
            "message": str(exc),
            "action": action,
            "resource": bucket_name,
        }

    return {"status": "error", "message": "unhandled action", "action": action}


def _log_remediation(execution_id: str, finding: dict, action: str, result: dict, approved_by: str) -> None:
    ttl = int(time.time()) + (90 * 86400)
    table.put_item(Item={
        "pk": f"REMEDIATION#{execution_id}",
        "sk": datetime.now(timezone.utc).isoformat(),
        "execution_id": execution_id,
        "action": action,
        "finding_id": finding.get("id", "unknown"),
        "resource_id": finding.get("resource_id", "unknown"),
        "result_status": result.get("status"),
        "result_message": result.get("message"),
        "approved_by": approved_by,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "ttl": ttl,
    })
