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
  description = "EKS control-plane version. Check `aws eks describe-addon-versions` or the AWS console for the currently supported range before relying on this default — EKS deprecates old versions on its own schedule."
  type        = string
  default     = "1.31"
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
  description = "CIDR allowed to reach the EKS API's public endpoint (kubectl/helm from outside the cluster). Same convention as terraform/dev/variables.tf — open by default, narrow to your own IP/32 before relying on this for longer than a quick test."
  type        = string
  default     = "0.0.0.0/0"
}
