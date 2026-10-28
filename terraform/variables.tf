variable "aws_region" {
  description = "AWS region to deploy everything into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix used for naming all resources."
  type        = string
  default     = "tech-challenge-2"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Keep cluster-autoscaler's image on the same minor version."
  type        = string
  default     = "1.35"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

# ---------------------------------------------------------------------------
# Node group sizing (challenge spec: t3.small, 1 node always on, up to 4)
# ---------------------------------------------------------------------------
variable "node_instance_type" {
  description = "Instance type for the EKS managed node group."
  type        = string
  default     = "t3.small"
}

variable "node_min_size" {
  description = "Nodes that stay running at all times."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum nodes the Cluster Autoscaler may scale out to."
  type        = number
  default     = 4
}

variable "node_desired_size" {
  description = "Initial node count (afterwards the Cluster Autoscaler owns this value)."
  type        = number
  default     = 1
}

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------
variable "app_name" {
  description = "Name of the application, used for the ECR repository and Helm release."
  type        = string
  default     = "hello-world"
}

variable "app_namespace" {
  description = "Kubernetes namespace the application is deployed into."
  type        = string
  default     = "hello-world"
}

# ---------------------------------------------------------------------------
# GitOps (GitHub Actions + Argo CD)
# ---------------------------------------------------------------------------
variable "github_repository" {
  description = "GitHub repository in owner/name form, e.g. \"octocat/tech-challenge-2\"."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "Use the owner/name form, e.g. octocat/tech-challenge-2."
  }
}

variable "gitops_branch" {
  description = "Branch GitHub Actions builds from and Argo CD tracks."
  type        = string
  default     = "gitops"
}

variable "github_token" {
  description = "Fine-grained GitHub token with read-only Contents access, so Argo CD can read the private repo."
  type        = string
  sensitive   = true
}

variable "create_github_oidc_provider" {
  description = "Set to false if the AWS account already has the token.actions.githubusercontent.com OIDC provider."
  type        = bool
  default     = true
}
