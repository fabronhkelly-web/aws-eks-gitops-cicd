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
# Jenkins
# ---------------------------------------------------------------------------
variable "jenkins_instance_type" {
  description = "Instance type for the Jenkins server (needs room for Docker builds)."
  type        = string
  default     = "t3.medium"
}

variable "jenkins_allowed_cidrs" {
  description = "CIDR blocks allowed to reach the Jenkins UI on port 8080, e.g. [\"203.0.113.10/32\"]."
  type        = list(string)

  validation {
    condition     = length(var.jenkins_allowed_cidrs) > 0
    error_message = "Provide at least one CIDR (your public IP as x.x.x.x/32)."
  }
}
