output "guardrail_id" { value = aws_bedrock_guardrail.cloudops.guardrail_id }
output "guardrail_arn" { value = aws_bedrock_guardrail.cloudops.guardrail_arn }
# Version is DRAFT until aws_bedrock_guardrail_version is re-added
output "guardrail_version" { value = "DRAFT" }
