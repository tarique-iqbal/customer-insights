variable "aws_region" {
  description = "Region this runs in. Free-Tier eligibility varies by region and account age — check the Billing console before relying on this being free."
  type        = string
  default     = "ap-southeast-1"
}

variable "instance_type" {
  description = "Applies to both nodes. Started on the Free-Tier-eligible t2.micro (~1GiB RAM), but that OOMKilled MySQL mid-InnoDB-init (exit 137, see kubernetes/chart/values-dev.yaml) — 8.0's real startup footprint needs more regardless of how the Pod's own memory limit is tuned. t3.medium has the headroom for that and is the default now, but it is NOT Free-Tier-eligible — it bills by the hour, so don't leave this environment up longer than you need it (see run.sh --destroy)."
  type        = string
  default     = "t3.medium"
}

variable "allowed_admin_cidr" {
  description = "CIDR allowed to reach the k3s API (6443) for kubectl/helm. Open by default (throwaway environment); narrow to your own IP/32 to lock it down."
  type        = string
  default     = "0.0.0.0/0"
}

variable "k3s_version" {
  description = "Pinned k3s version for the installer, so a test run is reproducible rather than always pulling latest."
  type        = string
  default     = "v1.30.4+k3s1"
}

variable "ssh_public_key_path" {
  description = "Local SSH public key, imported as this environment's EC2 key pair for human access (control-plane only). Generate one with `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_lab -N \"\"` if you don't have one — the private key never leaves your machine, Terraform only reads the .pub file."
  type        = string
}

variable "name" {
  description = "Prefix for every resource name/tag — keeps this unambiguous from the production Terraform."
  type        = string
  default     = "csat-dev"
}
