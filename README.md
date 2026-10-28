# Tech Challenge 2: GitOps branch (GitHub Actions + Argo CD)

This is the **required GitOps alternative**. It uses the same app, Dockerfile, Helm chart and EKS cluster as `main`. The difference is the CI/CD:

| | `main` branch | `gitops` branch (this one) |
|---|---|---|
| CI (test, build, push to ECR) | Jenkins on EC2 | **GitHub Actions** (`.github/workflows/ci-gitops.yml`) |
| CD (deploy to EKS) | Jenkins runs `helm upgrade` (push model) | **Argo CD** syncs the Helm chart from Git (pull model) |
| AWS credentials | Jenkins EC2 instance role | GitHub **OIDC** → short-lived IAM role. No stored keys |
| Source of truth for what's running | Last pipeline run | **This branch**: `charts/hello-world/values.yaml` |

**Deployed application URL:** http://k8s-hellowor-hellowor-de6f09c274-774402913.us-east-1.elb.amazonaws.com/ (deployed by Argo CD; `/info` shows the image tag built by GitHub Actions)

---

## How it works

```
 git push (app/**) to gitops
        │
        ▼
 ┌──────────────── GitHub Actions: ci-gitops ─────────────────┐
 │ pytest → assume IAM role via OIDC → docker build → push ECR │──────▶ Amazon ECR
 │ → yq sets image.tag=<sha> in charts/hello-world/values.yaml │          │
 │ → commit "deploy: hello-world <sha>" back to gitops         │          │ pull
 └──────────────────────────────┬──────────────────────────────┘          │
                                │ Git is the source of truth              │
                                ▼                                         ▼
                    ┌───────── EKS cluster ───────────────────────────────────────┐
                    │ Argo CD (argocd ns) polls gitops every 60s, then helm-renders │
                    │ charts/hello-world (+ image.repository from Terraform) and    │
                    │ applies it to the hello-world ns. Auto-sync, prune, self-heal │
                    │                                                               │
                    │ hello-world: Deployment + HPA (1→12) + Service + Ingress→ALB   │
                    │ t3.small node group 1→4 (Cluster Autoscaler)                  │
                    └───────────────────────────────────────────────────────────────┘
```

Everything else (VPC, EKS, t3.small node group 1–4, ALB controller, metrics-server, Cluster Autoscaler, HPA on 50% CPU / 50% memory, max 3 pods per node) is the same as `main`. See the `main` README for the scaling design and the Terraform walkthrough. This branch adds `terraform/gitops.tf` and removes the Jenkins server.

---

## What's different in the code

| File | Purpose |
|---|---|
| `terraform/gitops.tf` | GitHub OIDC provider + IAM role (can only push to this ECR repo, and only from the `gitops` branch of your repo). Installs **Argo CD** (Helm, lean: no Dex/notifications) with read access to your private repo. **Bootstraps** one Argo CD `Application` (via the `argocd-apps` chart) pointing at `charts/hello-world` on this branch |
| `.github/workflows/ci-gitops.yml` | CI: tests → OIDC login → build & push `:<git-sha>` to ECR (skipped if that tag already exists) → bump `image.tag` in the chart → commit back to the branch |
| `charts/hello-world/values.yaml` | Same chart. `image.tag` is now written by CI, and `image.repository` comes from the Argo CD Application (Terraform knows the ECR URL) |
| `terraform/variables.tf` | Adds `github_repository`, `gitops_branch`, `github_token`, `create_github_oidc_provider`. Removes the Jenkins variables |

Design choices:
- **No AWS keys in GitHub.** The workflow trades its OIDC token for a 1-hour session on a role whose trust policy is pinned to `repo:<owner>/<repo>:ref:refs/heads/gitops`.
- **No cluster credentials outside the cluster.** CI never talks to Kubernetes. It only changes Git. Argo CD pulls from inside the cluster.
- **Immutable, traceable images.** Tags are the commit SHA, and ECR is set to immutable tags.
- **Drift is corrected.** `selfHeal: true` reverts manual `kubectl edit`s, and `prune: true` removes resources deleted from Git.
- The CI commit only touches `charts/`, which is outside the workflow's `paths` filter. Commits made with `GITHUB_TOKEN` don't start workflows either, so there's no build loop.

---

## Setup

### Prerequisites

The same tools as `main` (AWS CLI v2, Terraform ≥ 1.5, kubectl, optionally Helm), plus:
- The private GitHub repo with this branch pushed (`git push -u origin gitops`) and your mentor added as a collaborator.
- A **fine-grained personal access token** limited to this repo with **Contents: Read-only**, for Argo CD.

### 1. Provision infrastructure + Argo CD

```bash
git checkout gitops
cd terraform
cp terraform.tfvars.example terraform.tfvars      # set github_repository = "<owner>/<repo>"
export TF_VAR_github_token="github_pat_..."         # keeps the token out of files
terraform init
terraform apply                                    # ~15–20 min
$(terraform output -raw configure_kubectl)
```

> If your AWS account already has the `token.actions.githubusercontent.com` OIDC provider, set `create_github_oidc_provider = false`.

### 2. Configure the GitHub repository

**Settings → Secrets and variables → Actions → Variables → New repository variable**:

| Name | Value |
|---|---|
| `AWS_ROLE_ARN` | `terraform output -raw github_actions_role_arn` |
| `AWS_REGION` | `terraform output -raw aws_region` |
| `ECR_REPOSITORY` | `hello-world` |

These are variables, not secrets, because none of them is sensitive. Also check that **Settings → Actions → General → Workflow permissions** allows read and write. If `gitops` is a protected branch, let `github-actions[bot]` push to it.

### 3. Run the first build

Until CI has pushed an image, Argo CD shows the app as *Degraded* (no image yet). Start the first build:

- **Actions → ci-gitops → Run workflow** (branch `gitops`), or
- push any change under `app/`.

The workflow pushes `hello-world:<sha>` to ECR and commits `deploy: hello-world <sha>`. Argo CD picks that up within about a minute.

### 4. Watch Argo CD

```bash
kubectl -n argocd get applications            # SYNC STATUS: Synced, HEALTH: Healthy
kubectl -n argocd port-forward svc/argocd-server 8080:443
# open https://localhost:8080, user: admin
$(terraform output -raw argocd_admin_password_command)
```

### 5. Get the application URL

```bash
kubectl get ingress hello-world -n hello-world \
  -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}/{"\n"}'
curl http://<hostname>/        # Hello, World!
curl http://<hostname>/info    # {"pod": "...", "version": "<git sha>"}
```

### 6. Day-to-day flow

```bash
# change the app
vim app/app.py && git commit -am "feat: ..." && git push
# → Actions builds and pushes :<sha>, then commits the tag
# → Argo CD rolls it out (rolling update, zero downtime)

# roll back = revert the deploy commit
git revert <deploy-commit> && git push       # Argo CD redeploys the previous tag
```

To demonstrate autoscaling, use `./scripts/load-test.sh` as described in the `main` README.

---

## Teardown

Delete the Argo CD Application first. Its finalizer removes the app's resources, including the ALB, which Terraform didn't create:

```bash
kubectl -n argocd delete application hello-world --wait
cd terraform && terraform destroy
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Workflow fails at *Configure AWS credentials* | Check `AWS_ROLE_ARN`/`AWS_REGION` variables, that the run is on the `gitops` branch, and that `github_repository` in tfvars matches `<owner>/<repo>` exactly (case-sensitive) |
| Workflow fails at *Commit and push* | Set workflow permissions to read and write, or let the bot push past branch protection |
| Argo CD app `ComparisonError` / repo not accessible | Token expired or lacks Contents read. Re-run `terraform apply` with a new `TF_VAR_github_token` |
| App `Degraded`, pods `ImagePullBackOff` | CI hasn't pushed the tag in `values.yaml` yet. Run the workflow |
| Ingress has no address | `kubectl logs -n kube-system deploy/aws-load-balancer-controller` |
