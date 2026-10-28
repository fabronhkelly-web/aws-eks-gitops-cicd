# Cluster add-ons the challenge relies on:
#   * metrics-server              -> feeds CPU/memory metrics to the HPA
#   * aws-load-balancer-controller -> turns the app's Ingress into an ALB
#   * cluster-autoscaler          -> scales the node group between 1 and 4 nodes
# Each controller that calls AWS APIs gets its own IAM role via IRSA.

# --- metrics-server -----------------------------------------------------------
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.13.0"

  depends_on = [module.eks]
}

# --- AWS Load Balancer Controller --------------------------------------------
# Policy vendored from the controller's docs/install/iam_policy.json (v3.6.2),
# as recommended by the AWS install guide.
resource "aws_iam_policy" "aws_lb_controller" {
  name   = "${local.cluster_name}-aws-lb-controller"
  policy = file("${path.module}/policies/aws-load-balancer-controller.json")
}

module "aws_lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.60"

  role_name = "${local.cluster_name}-aws-lb-controller"

  role_policy_arns = {
    controller = aws_iam_policy.aws_lb_controller.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.6.2"

  values = [yamlencode({
    clusterName  = module.eks.cluster_name
    region       = var.aws_region
    vpcId        = module.vpc.vpc_id
    replicaCount = 1 # one replica is plenty on a 1-4 node t3.small cluster
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.aws_lb_controller_irsa.iam_role_arn
      }
    }
  })]

  depends_on = [module.eks]
}

# --- Cluster Autoscaler -------------------------------------------------------
# EKS managed node groups tag their Auto Scaling group with
# k8s.io/cluster-autoscaler/enabled and k8s.io/cluster-autoscaler/<cluster>,
# so auto-discovery works without extra tagging.
module "cluster_autoscaler_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.60"

  role_name                        = "${local.cluster_name}-cluster-autoscaler"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [module.eks.cluster_name]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  namespace  = "kube-system"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.59.0" # ships cluster-autoscaler v1.35.0, matching Kubernetes 1.35

  values = [yamlencode({
    cloudProvider = "aws"
    awsRegion     = var.aws_region
    autoDiscovery = {
      clusterName = module.eks.cluster_name
    }
    rbac = {
      serviceAccount = {
        create = true
        name   = "cluster-autoscaler"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.cluster_autoscaler_irsa.iam_role_arn
        }
      }
    }
    extraArgs = {
      "balance-similar-node-groups"      = true
      "skip-nodes-with-system-pods"      = false
      "scale-down-unneeded-time"         = "5m"
      "scale-down-delay-after-add"       = "5m"
      "scale-down-utilization-threshold" = "0.5"
    }
  })]

  depends_on = [module.eks]
}
