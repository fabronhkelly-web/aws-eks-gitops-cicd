# GitOps CI/CD
#
#   GitHub Actions (CI)  --OIDC-->  IAM role  --push-->  ECR
#          |
#          +-- commits the new image tag to charts/hello-world/values.yaml
#                                   |
#   Argo CD (CD, in-cluster)  <-----+  watches the gitops branch and syncs the
#                                      Helm chart into the hello-world namespace
#
# No long-lived AWS keys exist anywhere: GitHub Actions gets short-lived
# credentials through OIDC, and Argo CD deploys from inside the cluster.

# --- GitHub Actions -> AWS (OIDC) ---------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS no longer checks these for GitHub, but older provider versions require a value
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
  github_repo_url          = "https://github.com/${var.github_repository}.git"
}

resource "aws_iam_role" "github_actions" {
  name = "${var.project_name}-github-actions"

  # Only workflows running on the gitops branch of this one repo can assume the role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:ref:refs/heads/${var.gitops_branch}"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "ecr-push"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = aws_ecr_repository.app.arn
      },
    ]
  })
}

# --- Argo CD ------------------------------------------------------------------
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.11.6" # Argo CD v3.5

  # Lean install for a small cluster: no SSO (dex) or notifications.
  # The UI is reached with `kubectl port-forward`, so no extra load balancer.
  values = [yamlencode({
    dex           = { enabled = false }
    notifications = { enabled = false }
    configs = {
      cm = {
        # Check Git every 60s instead of the default 3 min
        "timeout.reconciliation" = "60s"
      }
      repositories = {
        app-repo = {
          url      = local.github_repo_url
          type     = "git"
          username = "x-access-token"
        }
      }
    }
  })]

  # Private repo access. set_sensitive keeps the token out of plan output.
  set_sensitive {
    name  = "configs.repositories.app-repo.password"
    value = var.github_token
  }

  depends_on = [module.eks]
}

# Bootstrap: one Argo CD Application pointing at the Helm chart in this repo.
# Terraform supplies the ECR repository URL; the CI workflow only bumps image.tag.
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.7"

  values = [yamlencode({
    applications = {
      (var.app_name) = {
        namespace  = "argocd"
        project    = "default"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = local.github_repo_url
          targetRevision = var.gitops_branch
          path           = "charts/hello-world"
          helm = {
            valueFiles = ["values.yaml"]
            parameters = [{
              name  = "image.repository"
              value = aws_ecr_repository.app.repository_url
            }]
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = var.app_namespace
        }
        syncPolicy = {
          automated = {
            prune    = true # delete resources removed from Git
            selfHeal = true # revert manual changes made in the cluster
          }
          retry = {
            limit = 5
            backoff = {
              duration    = "10s"
              factor      = 2
              maxDuration = "3m"
            }
          }
        }
      }
    }
  })]

  depends_on = [helm_release.argocd, kubernetes_namespace.app]
}
