terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36"
    }
  }

  # Recommended: keep state in S3 so it is shared and locked.
  # Create the bucket once, then uncomment and run `terraform init -migrate-state`.
  #
  # backend "s3" {
  #   bucket       = "my-tfstate-bucket"
  #   key          = "tech-challenge-2/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}
