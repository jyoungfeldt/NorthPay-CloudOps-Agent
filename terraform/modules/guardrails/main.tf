resource "aws_bedrock_guardrail" "cloudops" {
  name                      = "northpay-cloudops-${var.environment}"
  blocked_input_messaging   = "I can only help with NorthPay AWS cloud operations questions."
  blocked_outputs_messaging = "This response was blocked by the NorthPay content policy."

  # Topic policy: keep the agent on-topic
  topic_policy_config {
    topics_config {
      name       = "off-topic"
      definition = "Any topic not related to AWS cloud operations, security, cost management, or NorthPay's infrastructure."
      examples   = [
        "Tell me a joke",
        "Write me a poem",
        "What is the capital of France",
        "Help me write an email"
      ]
      type = "DENY"
    }
    topics_config {
      name       = "non-northpay-accounts"
      definition = "Questions about AWS accounts, resources, or infrastructure not belonging to NorthPay."
      type       = "DENY"
    }
  }

  # PII filter: don't return PII in responses
  sensitive_information_policy_config {
    pii_entities_config {
      type   = "EMAIL"
      action = "ANONYMIZE"
    }
    pii_entities_config {
      type   = "PHONE"
      action = "ANONYMIZE"
    }
    pii_entities_config {
      type   = "US_SOCIAL_SECURITY_NUMBER"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "BLOCK"
    }
  }

  # Word filter: block attempts to exfiltrate credentials
  word_policy_config {
    words_config { text = "access_key_id" }
    words_config { text = "secret_access_key" }
    words_config { text = "aws_secret" }
  }

  tags = {
    Environment = var.environment
  }
}

resource "aws_bedrock_guardrail_version" "cloudops" {
  guardrail_arn = aws_bedrock_guardrail.cloudops.guardrail_arn
  description   = "Initial version"
}
