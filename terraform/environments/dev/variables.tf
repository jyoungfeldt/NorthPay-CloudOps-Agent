variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "notification_email" {
  description = "Email address to receive approval notifications"
  type        = string
}
