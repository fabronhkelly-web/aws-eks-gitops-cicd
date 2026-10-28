provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

# Both the Helm and Kubernetes providers authenticate to EKS with a short-lived
# token from `aws eks get-token`, so no kubeconfig file is needed.
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  cluster_name = "${var.project_name}-eks"
  azs          = slice(data.aws_availability_zones.available.names, 0, 2)
  account_id   = data.aws_caller_identity.current.account_id

  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}
