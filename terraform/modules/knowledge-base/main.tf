# ── S3 bucket for runbooks ────────────────────────────────────────────────────

resource "aws_s3_bucket" "runbooks" {
  bucket = "northpay-cloudops-runbooks-${var.environment}-${var.aws_account_id}"
}

resource "aws_s3_bucket_versioning" "runbooks" {
  bucket = aws_s3_bucket.runbooks.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "runbooks" {
  bucket = aws_s3_bucket.runbooks.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "runbooks" {
  bucket                  = aws_s3_bucket.runbooks.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── Bedrock Knowledge Base IAM role ──────────────────────────────────────────

resource "aws_iam_role" "kb" {
  name = "northpay-${var.environment}-bedrock-kb"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = var.aws_account_id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "kb" {
  role = aws_iam_role.kb.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.runbooks.arn,
          "${aws_s3_bucket.runbooks.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0"
      }
    ]
  })
}

# ── OpenSearch Serverless collection (vector store) ───────────────────────────

resource "aws_opensearchserverless_security_policy" "kb_encryption" {
  name   = "northpay-kb-${var.environment}"
  type   = "encryption"
  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/northpay-kb-${var.environment}"]
    }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "kb_network" {
  name   = "northpay-kb-${var.environment}"
  type   = "network"
  policy = jsonencode([{
    Rules = [
      { ResourceType = "collection", Resource = ["collection/northpay-kb-${var.environment}"] },
      { ResourceType = "dashboard", Resource = ["collection/northpay-kb-${var.environment}"] }
    ]
    AllowFromPublic = false
  }])
}

resource "aws_opensearchserverless_access_policy" "kb" {
  name   = "northpay-kb-${var.environment}"
  type   = "data"
  policy = jsonencode([{
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/northpay-kb-${var.environment}"]
      Permission   = ["aoss:CreateCollectionItems", "aoss:DeleteCollectionItems",
                      "aoss:UpdateCollectionItems", "aoss:DescribeCollectionItems"]
    },
    {
      ResourceType = "index"
      Resource     = ["index/northpay-kb-${var.environment}/*"]
      Permission   = ["aoss:CreateIndex", "aoss:DeleteIndex", "aoss:UpdateIndex",
                      "aoss:DescribeIndex", "aoss:ReadDocument", "aoss:WriteDocument"]
    }]
    Principal = [aws_iam_role.kb.arn]
  }])
}

resource "aws_opensearchserverless_collection" "kb" {
  name = "northpay-kb-${var.environment}"
  type = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.kb_encryption,
    aws_opensearchserverless_security_policy.kb_network,
    aws_opensearchserverless_access_policy.kb
  ]
}

# ── Bedrock Knowledge Base ────────────────────────────────────────────────────

resource "aws_bedrockagent_knowledge_base" "runbooks" {
  name     = "northpay-runbooks-${var.environment}"
  role_arn = aws_iam_role.kb.arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0"
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.kb.arn
      vector_index_name = "northpay-runbooks"
      field_mapping {
        vector_field   = "embedding"
        text_field     = "text"
        metadata_field = "metadata"
      }
    }
  }
}

resource "aws_bedrockagent_data_source" "runbooks" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.runbooks.id
  name              = "northpay-runbooks-s3"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.runbooks.arn
    }
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = "HIERARCHICAL"
      hierarchical_chunking_configuration {
        level_configuration {
          max_tokens = 1500  # parent chunk
        }
        level_configuration {
          max_tokens = 300   # child chunk for retrieval
        }
        overlap_tokens = 60
      }
    }
  }
}
