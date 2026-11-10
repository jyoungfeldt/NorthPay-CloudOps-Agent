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
        Sid    = "S3RunbookAccess"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.runbooks.arn,
          "${aws_s3_bucket.runbooks.arn}/*"
        ]
      },
      {
        Sid      = "BedrockEmbeddingModel"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0"
      },
      {
        Sid    = "OpenSearchServerlessAccess"
        Effect = "Allow"
        Action = ["aoss:APIAccessAll"]
        Resource = "arn:aws:aoss:${var.aws_region}:${var.aws_account_id}:collection/*"
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
  # AllowFromPublic must be the literal value true (not a variable or expression).
  # Authentication and authorisation are enforced by the data access policy and
  # IAM — public network access does not mean unauthenticated access.
  policy = jsonencode([{
    Rules = [
      { ResourceType = "collection", Resource = ["collection/northpay-kb-${var.environment}"] },
      { ResourceType = "dashboard",  Resource = ["collection/northpay-kb-${var.environment}"] }
    ]
    AllowFromPublic = true
  }])
}

resource "aws_opensearchserverless_access_policy" "kb" {
  name   = "northpay-kb-${var.environment}"
  type   = "data"
  policy = jsonencode([
    {
      # KB IAM role: full index access for ingestion and retrieval
      Rules = [
        {
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
        }
      ]
      Principal = [aws_iam_role.kb.arn]
    },
    {
      # Caller identity: index access so Bedrock can create the vector index
      Rules = [
        {
          ResourceType = "index"
          Resource     = ["index/northpay-kb-${var.environment}/*"]
          Permission   = ["aoss:CreateIndex", "aoss:DescribeIndex",
                          "aoss:ReadDocument", "aoss:WriteDocument"]
        }
      ]
      Principal = ["arn:aws:iam::${var.aws_account_id}:root"]
    }
  ])
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

# ── Create vector index in OpenSearch Serverless ─────────────────────────────
# Bedrock Knowledge Base requires the index to exist before it can register
# the collection as a storage backend. The index must have exact field names
# and a knn_vector mapping for the embedding dimension (1024 for Titan Embed V2).

resource "null_resource" "create_vector_index" {
  triggers = {
    collection_arn = aws_opensearchserverless_collection.kb.arn
  }

  provisioner "local-exec" {
    interpreter = ["python3", "-c"]
    command     = <<-PYTHON
import boto3, json, requests, sys, time
from requests_aws4auth import AWS4Auth

aoss   = boto3.client('opensearchserverless', region_name='${var.aws_region}')
detail = aoss.batch_get_collection(names=['northpay-kb-${var.environment}'])
endpoint = detail['collectionDetails'][0]['collectionEndpoint']

creds = boto3.Session().get_credentials().get_frozen_credentials()
auth  = AWS4Auth(creds.access_key, creds.secret_key,
                 '${var.aws_region}', 'aoss', session_token=creds.token)

# Wait up to 60s for the collection to be fully ready
for _ in range(12):
    r = requests.get(f"{endpoint}/_cat/indices", auth=auth)
    if r.status_code != 403:
        break
    time.sleep(5)

# Check if index exists
r = requests.get(f"{endpoint}/northpay-runbooks", auth=auth)
if r.status_code == 200:
    print("Index already exists")
    sys.exit(0)

index_body = {
    "settings": {"index.knn": True},
    "mappings": {
        "properties": {
            "embedding": {
                "type": "knn_vector", "dimension": 1024,
                "method": {"name": "hnsw", "space_type": "l2",
                           "engine": "faiss",
                           "parameters": {"ef_construction": 512, "m": 16}}
            },
            "text":     {"type": "text"},
            "metadata": {"type": "text"}
        }
    }
}
r2 = requests.put(f"{endpoint}/northpay-runbooks", auth=auth,
                  json=index_body, headers={"Content-Type": "application/json"})
if r2.status_code not in (200, 201):
    print(f"ERROR: {r2.status_code} {r2.text}", file=sys.stderr)
    sys.exit(1)
print(f"Created index northpay-runbooks: {r2.status_code}")
PYTHON
  }

  depends_on = [
    aws_opensearchserverless_collection.kb,
    aws_iam_role_policy.kb,
    aws_opensearchserverless_access_policy.kb,
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
