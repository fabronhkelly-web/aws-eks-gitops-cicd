output "aws_region" {
  value = var.aws_region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_url" {
  description = "Push application images here."
  value       = aws_ecr_repository.app.repository_url
}

output "app_namespace" {
  value = var.app_namespace
}

output "jenkins_url" {
  description = "Jenkins UI (allow ~5 minutes after apply for bootstrap to finish)."
  value       = "http://${aws_instance.jenkins.public_dns}:8080"
}

output "jenkins_instance_id" {
  description = "Use with SSM: aws ssm start-session --target <id>"
  value       = aws_instance.jenkins.id
}
