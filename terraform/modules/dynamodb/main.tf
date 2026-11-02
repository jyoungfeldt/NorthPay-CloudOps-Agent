resource "aws_dynamodb_table" "audit" {
  name         = "northpay-cloudops-audit-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }

  # GSI for querying by session
  global_secondary_index {
    name            = "session-index"
    hash_key        = "session_id"
    projection_type = "ALL"
  }

  attribute {
    name = "session_id"
    type = "S"
  }

  # TTL: auto-expire audit records after 90 days
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Environment = var.environment
  }
}
