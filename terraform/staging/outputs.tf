output "aws_region" {
  description = "Echoes var.aws_region, so a script can target the right region without re-reading terraform.tfvars."
  value       = var.aws_region
}

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Only needed to build a kubeconfig by hand — running `aws eks update-kubeconfig --name <cluster_name> --region <aws_region>` does this for you."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

output "alb_controller_role_arn" {
  description = "Pass as the eks.amazonaws.com/role-arn annotation on the aws-load-balancer-controller Helm release's ServiceAccount — the IRSA role it assumes to call the EC2/ELB APIs."
  value       = aws_iam_role.alb_controller.arn
}
