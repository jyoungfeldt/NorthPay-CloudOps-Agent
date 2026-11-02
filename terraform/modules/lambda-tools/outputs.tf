output "tool_arns" {
  value = {
    security_hub = aws_lambda_function.security_hub.arn
    cost_explorer = aws_lambda_function.cost_explorer.arn
    remediate     = aws_lambda_function.remediate.arn
  }
}

output "remediate_lambda_arn" {
  value = aws_lambda_function.remediate.arn
}
