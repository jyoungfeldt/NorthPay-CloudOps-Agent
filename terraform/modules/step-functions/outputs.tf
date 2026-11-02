output "state_machine_arn" { value = aws_sfn_state_machine.approval.arn }
output "approval_topic_arn" { value = aws_sns_topic.approvals.arn }
