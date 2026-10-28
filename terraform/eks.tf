module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = local.cluster_name
  cluster_version = var.kubernetes_version

  # Public endpoint so you (and Jenkins) can run kubectl/helm; nodes stay private.
  cluster_endpoint_public_access = true

  # The identity running `terraform apply` becomes cluster admin.
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"

      # 1 node always on, scalable to 4. The module ignores later changes to
      # desired_size so it does not fight the Cluster Autoscaler.
      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      labels = {
        workload = "general"
      }
    }
  }

  # EKS access entries (replace the old aws-auth ConfigMap).
  # Jenkins gets admin rights scoped to the application namespace only.
  access_entries = {
    jenkins = {
      principal_arn = aws_iam_role.jenkins.arn

      policy_associations = {
        app_namespace_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
          access_scope = {
            type       = "namespace"
            namespaces = [var.app_namespace]
          }
        }
      }
    }
  }
}

# Namespace the pipeline deploys into. Created here so the Jenkins role only
# needs namespace-scoped permissions.
resource "kubernetes_namespace" "app" {
  metadata {
    name = var.app_namespace
  }

  depends_on = [module.eks]
}
