terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # All backend values are injected at init time via -backend-config flags.
  # The bucket must already exist: run the state bootstrap from
  # workshop-platform-eng first (cross-cutting concern, not owned by this repo).
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      application = var.app_name
      environment = "dev"
      managed-by  = "terraform"
      platform    = "platform-engineering"
    }
  }
}
