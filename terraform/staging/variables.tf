variable "aws_region" {
  description = "Region this runs in. Same account/region as terraform/dev by default — EKS and NAT Gateway pricing both vary by region."
  type        = string
  default     = "ap-southeast-1"
}

variable "name" {
  description = "Prefix for every resource name/tag, and the EKS cluster's own name — keeps this unambiguous from terraform/dev."
  type        = string
  default     = "csat-staging"
}

variable "vpc_cidr" {
  description = "Needs real address space for pod IPs: EKS's VPC CNI, unlike dev's flannel overlay, assigns pods real VPC IPs. A /16 gives each of the 4 /20 subnets below 4096 addresses. Chosen to not overlap terraform/dev's 10.50.0.0/24 or flannel's own 10.42.0.0/16 / 10.43.0.0/16 defaults."
  type        = string
  default     = "10.60.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS control-plane version. Standard support versions as of 2026-10-27: 1.34-1.37 — see https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html for the current table."
  type        = string
  default     = "1.34"
}

variable "node_instance_type" {
  description = "Same instance family terraform/dev settled on after its t2.micro OOMKill (see that module's own variables.tf) — reusing a known-good size rather than re-deriving one."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Node count. 2 so the cluster survives one node's maintenance/replacement without dropping to zero capacity."
  type        = number
  default     = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "allowed_admin_cidr" {
  description = "CIDR allowed to reach the EKS API's public endpoint. Deliberately left open (0.0.0.0/0), unlike terraform/dev/variables.tf's equivalent: deploy-staging.yml runs on GitHub-hosted runners, whose IPs are large, published ranges that change often — narrowing this to one IP (as an earlier version of terraform.tfvars did, for a human's own laptop) silently breaks that workflow's ability to reach the cluster at all. The real access boundary here is IAM + Kubernetes RBAC, not the network: see main.tf's \"GitHub Actions CI/CD identity\" section (trust policy scoped to this repo's main branch) and the aws_eks_access_entry/aws_eks_access_policy_association pair (scoped to AmazonEKSEditPolicy on just the csat namespace) — reaching the API server at all doesn't grant those permissions."
  type        = string
  default     = "0.0.0.0/0"
}

variable "github_repo" {
  description = "owner/repo this tier's GitHub Actions deploy role trusts (scopes the OIDC trust policy's :sub condition to this repo's main branch only)."
  type        = string
  default     = "tarique-iqbal/customer-insights"
}
