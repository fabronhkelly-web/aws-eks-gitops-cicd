module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = local.cluster_name
  cluster_version = var.kubernetes_version

  # Public endpoint so you can run kubectl/helm; nodes stay private.
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
      # Prefix delegation hands each ENI slot a /28 instead of a single IP.
      # Without it a t3.small can only run 11 pods, and the add-ons alone use 7.
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
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

      # Raise the per-node pod limit to match prefix delegation. 20 leaves
      # headroom for add-ons, 3 app pods and load-test pods while keeping the
      # kubelet's memory reservation (11 x maxPods + 255Mi) modest on 2 GiB.
      cloudinit_pre_nodeadm = [{
        content_type = "application/node.eks.aws"
        content      = <<-EOT
          ---
          apiVersion: node.eks.aws/v1alpha1
          kind: NodeConfig
          spec:
            kubelet:
              config:
                maxPods: 20
        EOT
      }]
    }
  }
}

# Namespace Argo CD deploys the application into.
resource "kubernetes_namespace" "app" {
  metadata {
    name = var.app_namespace
  }

  depends_on = [module.eks]
}
