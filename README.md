# Tech Challenge 2: Docker, Terraform, AWS EKS & Jenkins

A "Hello, World!" Flask app, containerised with Docker, running on an auto-scaling
Amazon EKS cluster built with Terraform, and deployed by a Jenkins CI/CD pipeline
(build → push to Amazon ECR → deploy with Helm).

> **Branches**
> - `main`: this README. Jenkins pipeline.
> - `gitops`: the required GitOps alternative. GitHub Actions builds and pushes to ECR, and Argo CD deploys the Helm chart. See that branch's README.

**Deployed application URL:** http://k8s-hellowor-hellowor-de6f09c274-763721802.us-east-1.elb.amazonaws.com/

---

## Architecture

```
 Developer ──git push──▶ GitHub (private repo)
                              │  pollSCM (every 2 min)
                              ▼
                    ┌──────────────────────┐
                    │ Jenkins (EC2, t3.med) │  IAM instance role, no stored keys
                    │ test → build → push   │──────────────▶ Amazon ECR (hello-world)
                    │ helm upgrade --install│                     │ image pull
                    └──────────┬───────────┘                     ▼
                               │ EKS access entry       ┌──────────────────────────────┐
                               └───────────────────────▶│ EKS 1.35 (private subnets)   │
                                                        │ managed node group: t3.small │
 User ──HTTP──▶ ALB (public subnets) ──────────────────▶│   min 1 · max 4 nodes        │
               (AWS Load Balancer Controller)           │ hello-world Deployment + HPA │
                                                        │ metrics-server · cluster-    │
                                                        │ autoscaler · LB controller   │
                                                        └──────────────────────────────┘
```

| Requirement | How it's met |
|---|---|
| Simple web app showing "Hello, World!" | `app/app.py` (Flask + gunicorn), with `/healthz` for probes and `/info` to show which pod answered |
| Dockerfile | `app/Dockerfile`: slim Python base, cached dependency layer, runs as non-root user |
| Terraform provisions EKS | `terraform/`: VPC, EKS, node group, ECR, IAM (IRSA), add-ons, Jenkins server |
| 4 nodes total, 1 always on, scalable to 4, t3.small | Managed node group `min_size=1`, `max_size=4`, `instance_types=["t3.small"]`, scaled by the Cluster Autoscaler |
| ALB | AWS Load Balancer Controller + `Ingress` with `ingressClassName: alb` |
| 1 pod per node, HPA up to 3 per node | HPA `minReplicas: 1` (1 node → 1 pod), `maxReplicas: 12` (3 × 4 nodes). Topology spread keeps pods even across nodes, and the 475m CPU request means at most 3 app pods fit on a t3.small (see [Scaling design](#scaling-design)) |
| HPA scales on 50% CPU or 50% memory | `autoscaling/v2` HPA with two `Resource` metrics, each targeting 50% |
| Jenkins builds, pushes to ECR, deploys with kubectl & Helm | `Jenkinsfile`: unit tests → `helm lint` → `docker build/push` → `helm upgrade --install --atomic` → `kubectl` checks → smoke test via the ALB |

---

## Repository layout

```
.
├── app/                     # Flask app, tests and Dockerfile
├── charts/hello-world/      # Helm chart: Deployment, Service, Ingress (ALB), HPA
├── terraform/               # All AWS infrastructure
│   ├── vpc.tf               #   VPC, public/private subnets, NAT
│   ├── eks.tf               #   EKS cluster, node group, Jenkins access entry, app namespace
│   ├── addons.tf            #   metrics-server, AWS LB Controller, Cluster Autoscaler (+ IRSA roles)
│   ├── ecr.tf               #   ECR repository + lifecycle policy
│   ├── jenkins.tf           #   Jenkins EC2 server, IAM role, security group
│   ├── templates/           #   Jenkins bootstrap script (user data)
│   └── policies/            #   Official IAM policy for the LB Controller
├── Jenkinsfile              # CI/CD pipeline
├── scripts/load-test.sh     # Generates load to demonstrate HPA + node autoscaling
└── .github/workflows/       # Static checks (pytest, terraform validate, helm lint)
```

---

## Prerequisites

| Tool | Version used | Purpose |
|---|---|---|
| AWS account + IAM user/role with admin rights | n/a | Terraform creates VPC, EKS, IAM, EC2, ECR |
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | 2.x | Auth for Terraform, kubectl and Helm |
| [Terraform](https://developer.hashicorp.com/terraform/install) | ≥ 1.5 | Infrastructure as code |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.35 | Inspect the cluster |
| [Helm](https://helm.sh/docs/intro/install/) | 3.x | Optional: manual deploys |
| Docker | any recent | Optional: run the app locally |

Configure credentials first, e.g. `aws configure` or `export AWS_PROFILE=...`, and check with `aws sts get-caller-identity`.

> **Cost note:** EKS control plane (~$0.10/h), 1–4 × t3.small, a t3.medium for Jenkins, one NAT gateway and one ALB. Expect roughly **$7–9 per day** at minimum size. Run `terraform destroy` when you're done (see [Teardown](#teardown)).

---

## Run the app locally

```bash
cd app
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
python -m pytest -q          # 3 tests
python app.py                # http://localhost:8080 → Hello, World!

# or with Docker
docker build -t hello-world .
docker run --rm -p 8080:8080 hello-world
```

---

## Deploy to AWS

### 1. Provision the infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Set jenkins_allowed_cidrs to your IP:  curl -s https://checkip.amazonaws.com
terraform init
terraform apply          # ~15–20 minutes
```

Useful outputs:

```bash
terraform output                       # all values
$(terraform output -raw configure_kubectl)   # writes your kubeconfig
kubectl get nodes                      # 1 × t3.small Ready
kubectl get pods -n kube-system        # aws-load-balancer-controller, cluster-autoscaler, metrics-server …
```

### 2. Put the code in a private GitHub repo

```bash
git remote add origin git@github.com:<you>/tech-challenge-2.git
git push -u origin main gitops
```

Then go to **Settings → Collaborators** and add your mentor.

### 3. Unlock Jenkins

The server takes ~5 minutes after `apply` to finish installing. Get the initial admin password over SSM (no SSH key needed):

```bash
aws ssm start-session --target "$(terraform output -raw jenkins_instance_id)"
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Open `terraform output -raw jenkins_url`, paste the password, choose **Install suggested plugins**, and create your admin user.

### 4. Create the pipeline job

1. **Manage Jenkins → Credentials → (global) → Add credentials**
   *Kind:* Username with password · *Username:* your GitHub user · *Password:* a [fine-grained personal access token](https://github.com/settings/personal-access-tokens) with **Contents: Read-only** on this repo · *ID:* `github`
2. **New Item → Pipeline** named `hello-world`.
3. *Pipeline → Definition:* **Pipeline script from SCM** · *SCM:* Git · *Repository URL:* `https://github.com/<you>/tech-challenge-2.git` · *Credentials:* `github` · *Branch:* `*/main` · *Script Path:* `Jenkinsfile`
4. Save, then click **Build Now**. The first run registers the parameters and the polling trigger. Check that the parameter defaults match `terraform output` (region, cluster name).

From now on, every push to `main` is picked up within ~2 minutes.

### 5. What the pipeline does

| Stage | Details |
|---|---|
| Checkout | Tags the image with the short git SHA, so every build is traceable and ECR tags stay immutable |
| Unit tests | Runs `pytest` in a throwaway `python:3.12-slim` container |
| Lint chart | `helm lint charts/hello-world` |
| Build & push image | `aws ecr get-login-password \| docker login`, `docker build`, `docker push`. Skips the build if that SHA is already in ECR |
| Deploy to EKS | `aws eks update-kubeconfig`, then `helm upgrade --install --atomic --wait`, which rolls back on its own if the new pods never become ready. `kubectl get` prints the result |
| Smoke test | Waits for the ALB hostname on the Ingress and checks `GET /` returns "Hello, World!". The URL is shown as the build description |

Jenkins authenticates with its **EC2 instance role**, so no AWS keys are stored in Jenkins. The role can only push to this one ECR repo and describe this one cluster. Inside Kubernetes, the role's **EKS access entry** grants admin only in the `hello-world` namespace.

### 6. Get the application URL

```bash
kubectl get ingress hello-world -n hello-world \
  -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}/{"\n"}'
curl http://<that-hostname>/        # Hello, World!
curl http://<that-hostname>/info    # {"pod": "...", "version": "<git sha>"}
```

The URL is also shown on each successful Jenkins build. Paste it at the top of this README for your submission.

---

## Scaling design

```
          HPA (pods)                                  Cluster Autoscaler (nodes)
 CPU > 50% or memory > 50% of requests        a pod is Pending because no node has room
              │                                                 │
              ▼                                                 ▼
   replicas 1 → … → 12  ──── pods that don't fit go Pending ──▶ node group 1 → … → 4
```

- **1 node always on:** node group `min_size = 1`. **Up to 4:** `max_size = 4`. `desired_size` belongs to the Cluster Autoscaler after the first apply (the Terraform module ignores later changes to it).
- **1 pod per node, up to 3:** the HPA starts at 1 replica on the 1 node. `topologySpreadConstraints` (`maxSkew: 1` across `kubernetes.io/hostname`) keeps the per-node count even. A t3.small has about 1930m allocatable CPU, and each app pod requests **475m**, so **3 fit on a node and a 4th does not**. That holds even on the first node, which also runs the cluster add-ons. When the HPA wants pod #4, it goes Pending and the Cluster Autoscaler adds a node. At most 4 nodes × 3 pods = **12 replicas**, which is `maxReplicas`.
- **Pod density:** the VPC CNI runs with prefix delegation and nodes allow 20 pods. Without that, a t3.small is limited to 11 pod IPs, and the add-ons alone use 7.
- **50% CPU or 50% memory:** the HPA has two `Resource` metrics. Kubernetes computes the replica count each metric needs and uses the larger one, so whichever crosses 50% first drives scaling.
- **Scale-down:** the HPA waits 5 minutes before removing pods. The Cluster Autoscaler removes a node after it has been under 50% utilised for 5 minutes, then the cluster settles back to 1 node.

### Demonstrate it

```bash
# terminal 1
kubectl get hpa,pods -n hello-world -o wide -w
# terminal 2
kubectl get nodes -w
# terminal 3
./scripts/load-test.sh 6       # start load
./scripts/load-test.sh stop    # stop load
```

You'll see CPU climb past 50%, replicas go up, pods go Pending, new t3.small nodes join, and the pods spread across them. Once you stop the load, everything scales back to 1 pod on 1 node.

---

## Terraform explained

| File | What it creates | Notes |
|---|---|---|
| `versions.tf` | Provider pins (AWS 5.x, Helm 2.x, Kubernetes 2.x) | Has a commented S3 backend block. Turn it on for shared, locked state |
| `providers.tf` | Provider config, AZ lookup, common tags | Helm and Kubernetes providers log in with `aws eks get-token`, so no kubeconfig file is needed |
| `vpc.tf` | VPC across 2 AZs: 2 public + 2 private subnets, 1 NAT gateway | Subnets carry the `kubernetes.io/role/elb` and `internal-elb` tags the LB Controller uses to find them |
| `eks.tf` | EKS cluster (`terraform-aws-modules/eks` v20), managed node group (AL2023, t3.small, 1–4, `maxPods: 20`), core add-ons (VPC CNI with prefix delegation), access entry for Jenkins, app namespace | Uses EKS **access entries** (API auth mode) instead of the old `aws-auth` ConfigMap. Whoever runs `apply` becomes cluster admin |
| `addons.tf` | metrics-server, AWS Load Balancer Controller, Cluster Autoscaler (all Helm), each with its own IRSA role | The LB Controller policy is the official one from the controller repo. Cluster Autoscaler finds the node group through the ASG tags EKS adds automatically. Its version (1.35) matches the cluster |
| `ecr.tf` | ECR repo with immutable tags, scan-on-push, keeps the newest 20 images | `force_delete` lets `destroy` remove the repo even with images in it |
| `jenkins.tf` | Jenkins EC2 (AL2023, t3.medium, 30 GB gp3, IMDSv2), IAM role + instance profile, security group | Port 8080 is open only to `jenkins_allowed_cidrs`, with no SSH (use SSM). The role has least-privilege ECR/EKS permissions |
| `templates/jenkins-user-data.sh.tpl` | Installs Java 21, Jenkins LTS, Docker, kubectl (matched to the cluster) and Helm | Log at `/var/log/jenkins-bootstrap.log` |
| `outputs.tf` | Cluster name, kubeconfig command, ECR URL, Jenkins URL/instance ID | |

Key variables (`variables.tf`): `aws_region`, `project_name`, `kubernetes_version` (default 1.35), `node_instance_type` (t3.small), `node_min_size`/`node_max_size`/`node_desired_size` (1/4/1), `jenkins_allowed_cidrs` (required).

---

## Teardown

The ALB is created by the LB Controller rather than by Terraform, so remove it first or the VPC can't be deleted:

```bash
helm uninstall hello-world -n hello-world
# wait ~1 minute for the ALB to be deleted, then
cd terraform && terraform destroy
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Jenkins UI doesn't load | Wait ~5 minutes after apply. Check `jenkins_allowed_cidrs` matches your current IP. Read the log with `sudo tail -f /var/log/jenkins-bootstrap.log` (over SSM) |
| Pipeline: `docker: permission denied` | `sudo systemctl restart jenkins` (picks up the `docker` group) |
| Pipeline: `Unauthorized` from kubectl | Check the `EKS_CLUSTER_NAME`/`AWS_REGION` parameters, and that `terraform apply` finished (it creates the access entry) |
| Ingress has no address | `kubectl logs -n kube-system deploy/aws-load-balancer-controller`. Usually subnet tags or the IAM role |
| HPA shows `<unknown>` targets | metrics-server needs ~1 minute after start. Check with `kubectl top pods -n hello-world` |
| Pods stay Pending, no new node | `kubectl logs -n kube-system deploy/cluster-autoscaler`. Check it isn't already at `max_size` |
