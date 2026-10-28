#!/bin/bash
# Bootstraps the Jenkins server on Amazon Linux 2023.
# Progress log: /var/log/jenkins-bootstrap.log
set -euxo pipefail
exec > >(tee /var/log/jenkins-bootstrap.log) 2>&1

dnf -y upgrade --refresh
dnf -y install java-21-amazon-corretto-headless git docker fontconfig unzip

# --- Docker -------------------------------------------------------------------
systemctl enable --now docker

# --- Jenkins (LTS) ------------------------------------------------------------
# The repo file carries the current signing key location; dnf imports it with -y.
curl -fsSL -o /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/rpm-stable/jenkins.repo \
  || curl -fsSL -o /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
dnf -y install jenkins
usermod -aG docker jenkins   # lets pipeline steps run `docker build`

# --- kubectl (same minor version as the cluster) ------------------------------
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v${kubectl_version}/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# --- Helm 3 -------------------------------------------------------------------
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# AWS CLI v2 ships with AL2023; make sure it's on PATH for the jenkins user
aws --version

systemctl enable --now jenkins

echo "Jenkins bootstrap complete. Initial admin password:"
cat /var/lib/jenkins/secrets/initialAdminPassword || true
