# ── Shared Lambda execution role (least-privilege per tool) ──────────────────

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ── Security Hub query tool ───────────────────────────────────────────────────

resource "aws_iam_role" "security_hub" {
  name               = "northpay-${var.environment}-tool-security-hub"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "security_hub" {
  role = aws_iam_role.security_hub.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecurityHubReadOnly"
        Effect = "Allow"
        Action = [
          "securityhub:GetFindings",
          "securityhub:BatchGetFindings",
          "securityhub:ListFindingAggregators"
        ]
        Resource = "*"
      },
      {
        Sid    = "AuditLog"
        Effect = "Allow"
        Action = ["dynamodb:PutItem"]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/${var.audit_table}"
      },
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "security_hub" {
  function_name = "northpay-${var.environment}-tool-security-hub"
  role          = aws_iam_role.security_hub.arn
  handler       = "security_hub.handler"
  runtime       = "python3.12"
  timeout       = 30

  filename         = data.archive_file.tools.output_path
  source_code_hash = data.archive_file.tools.output_base64sha256

  environment {
    variables = {
      AUDIT_TABLE = var.audit_table
      ENVIRONMENT = var.environment
    }
  }
}

# ── Cost Explorer query tool ──────────────────────────────────────────────────

resource "aws_iam_role" "cost_explorer" {
  name               = "northpay-${var.environment}-tool-cost-explorer"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "cost_explorer" {
  role = aws_iam_role.cost_explorer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ce:GetCostAndUsage", "ce:GetAnomalies", "ce:GetCostForecast"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/${var.audit_table}"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "cost_explorer" {
  function_name    = "northpay-${var.environment}-tool-cost-explorer"
  role             = aws_iam_role.cost_explorer.arn
  handler          = "cost_explorer.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.tools.output_path
  source_code_hash = data.archive_file.tools.output_base64sha256
  environment {
    variables = {
      AUDIT_TABLE = var.audit_table
      ENVIRONMENT = var.environment
    }
  }
}

# ── Remediation tool (separate role — write permissions) ─────────────────────

resource "aws_iam_role" "remediate" {
  name               = "northpay-${var.environment}-tool-remediate"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "remediate" {
  role = aws_iam_role.remediate.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Remediation"
        Effect = "Allow"
        Action = [
          "s3:PutBucketPublicAccessBlock",
          "s3:PutBucketEncryption",
          "s3:GetBucketPublicAccessBlock"
        ]
        Resource = "arn:aws:s3:::northpay-*"  # scope to NorthPay buckets only
      },
      {
        Sid    = "AuditLog"
        Effect = "Allow"
        Action = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/${var.audit_table}"
      },
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "remediate" {
  function_name    = "northpay-${var.environment}-tool-remediate"
  role             = aws_iam_role.remediate.arn
  handler          = "remediate.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.tools.output_path
  source_code_hash = data.archive_file.tools.output_base64sha256
  environment {
    variables = {
      AUDIT_TABLE = var.audit_table
      ENVIRONMENT = var.environment
    }
  }
}

# ── Package the Lambda code ───────────────────────────────────────────────────

data "archive_file" "tools" {
  type        = "zip"
  source_dir  = "${path.root}/../../../agent/tools"
  output_path = "${path.root}/.terraform/lambda-tools.zip"
}
