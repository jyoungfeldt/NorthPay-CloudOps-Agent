output "knowledge_base_id" { value = aws_bedrockagent_knowledge_base.runbooks.id }
output "runbooks_bucket_name" { value = aws_s3_bucket.runbooks.bucket }
output "data_source_id" { value = aws_bedrockagent_data_source.runbooks.data_source_id }
