# Human approval workflow using Step Functions waitForTaskToken pattern

resource "aws_sns_topic" "approvals" {
  name = "northpay-cloudops-approvals-${var.environment}"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.approvals.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_iam_role" "sfn" {
  name = "northpay-${var.environment}-sfn-approval"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn" {
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = var.remediation_lambda_arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.approvals.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/${var.audit_table}"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogDelivery", "logs:PutLogEvents",
                    "logs:GetLogDelivery", "logs:UpdateLogDelivery",
                    "logs:DeleteLogDelivery", "logs:ListLogDeliveries",
                    "logs:PutResourcePolicy", "logs:DescribeResourcePolicies",
                    "logs:DescribeLogGroups"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_sfn_state_machine" "approval" {
  name     = "northpay-cloudops-approval-${var.environment}"
  role_arn = aws_iam_role.sfn.arn

  # Express workflow for faster execution and lower cost
  type = "STANDARD"

  definition = jsonencode({
    Comment = "NorthPay CloudOps Agent — human approval before remediation"
    StartAt = "LogProposal"
    States = {
      LogProposal = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:putItem"
        Parameters = {
          TableName = var.audit_table
          Item = {
            pk            = { "S.$" = "$.execution_id" }
            sk            = { S = "PROPOSAL" }
            session_id    = { "S.$" = "$.session_id" }
            finding       = { "S.$" = "States.JsonToString($.finding)" }
            proposed_fix  = { "S.$" = "$.proposed_fix" }
            status        = { S = "PENDING_APPROVAL" }
            timestamp     = { "S.$" = "$$.Execution.StartTime" }
            ttl           = { "S.$" = "$$.Execution.StartTime" }
          }
        }
        Next = "SendApprovalRequest"
      }

      SendApprovalRequest = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish.waitForTaskToken"
        HeartbeatSeconds = 86400
        Parameters = {
          TopicArn    = aws_sns_topic.approvals.arn
          "Message.$" = "States.Format('NorthPay CloudOps Agent requires approval. Finding: {}. Proposed fix: {}. Task token: {}', $.finding.title, $.proposed_fix, $$.Task.Token)"
          Subject     = "CloudOps Agent Approval Required"
        }
        ResultPath = "$.approval"
        Catch = [{
          ErrorEquals = ["States.HeartbeatTimeout", "States.TaskFailed"]
          Next        = "RemediationRejected"
        }]
        Next = "ApplyRemediation"
      }

      ApplyRemediation = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = var.remediation_lambda_arn
          Payload = {
            "finding.$"      = "$.finding"
            "proposed_fix.$" = "$.proposed_fix"
            "approved_by.$"  = "$.approval.approver"
          }
        }
        ResultPath = "$.remediation_result"
        Next       = "LogSuccess"
      }

      LogSuccess = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName = var.audit_table
          Key = {
            pk = { "S.$" = "$.execution_id" }
            sk = { S = "PROPOSAL" }
          }
          UpdateExpression = "SET #s = :status, remediation_result = :result"
          ExpressionAttributeNames  = { "#s" = "status" }
          ExpressionAttributeValues = {
            ":status" = { S = "APPLIED" }
            ":result" = { "S.$" = "States.JsonToString($.remediation_result)" }
          }
        }
        End = true
      }

      RemediationRejected = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName = var.audit_table
          Key = {
            pk = { "S.$" = "$.execution_id" }
            sk = { S = "PROPOSAL" }
          }
          UpdateExpression = "SET #s = :status"
          ExpressionAttributeNames  = { "#s" = "status" }
          ExpressionAttributeValues = {
            ":status" = { S = "REJECTED" }
          }
        }
        End = true
      }
    }
  })
}
