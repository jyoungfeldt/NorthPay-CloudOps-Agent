terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.75"
    }
  }

  backend "s3" {
    bucket       = "northpay-tfstate-595981720885"
    key          = "cloudops-agent/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "northpay-cloudops-agent"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ── Audit DynamoDB table ───────────────────────────────────────────────────────

module "dynamodb" {
  source      = "../../modules/dynamodb"
  environment = var.environment
}

# ── S3 bucket + Bedrock Knowledge Base + OpenSearch vector store ──────────────

module "knowledge_base" {
  source         = "../../modules/knowledge-base"
  environment    = var.environment
  aws_account_id = data.aws_caller_identity.current.account_id
  aws_region     = var.aws_region
}

# ── Bedrock Guardrails ────────────────────────────────────────────────────────

module "guardrails" {
  source      = "../../modules/guardrails"
  environment = var.environment
}

# ── Lambda tool functions ─────────────────────────────────────────────────────

module "lambda_tools" {
  source         = "../../modules/lambda-tools"
  environment    = var.environment
  aws_account_id = data.aws_caller_identity.current.account_id
  aws_region     = var.aws_region
  audit_table    = module.dynamodb.table_name
}

# ── Step Functions human-approval workflow ────────────────────────────────────

module "step_functions" {
  source                 = "../../modules/step-functions"
  environment            = var.environment
  aws_account_id         = data.aws_caller_identity.current.account_id
  aws_region             = var.aws_region
  remediation_lambda_arn = module.lambda_tools.remediate_lambda_arn
  audit_table            = module.dynamodb.table_name
  notification_email     = var.notification_email
}

# ── Bedrock Agent (AgentCore) ─────────────────────────────────────────────────
# TODO Week 4: uncomment once terraform/modules/bedrock-agent/ is built.
# module "bedrock_agent" {
#   source            = "../../modules/bedrock-agent"
#   environment       = var.environment
#   aws_account_id    = data.aws_caller_identity.current.account_id
#   aws_region        = var.aws_region
#   knowledge_base_id = module.knowledge_base.knowledge_base_id
#   guardrail_id      = module.guardrails.guardrail_id
#   guardrail_version = module.guardrails.guardrail_version
#   lambda_tool_arns  = module.lambda_tools.tool_arns
#   sfn_arn           = module.step_functions.state_machine_arn
# }
