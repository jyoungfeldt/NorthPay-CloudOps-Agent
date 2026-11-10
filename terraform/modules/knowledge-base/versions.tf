terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.75"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
}
