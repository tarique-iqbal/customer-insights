output "aws_region" {
  description = "Echoes var.aws_region, so a script can target the right region without re-reading terraform.tfvars."
  value       = var.aws_region
}

output "control_plane_instance_id" {
  description = "Informational only — SSH (not SSM) is the human access path now; see control_plane_public_ip."
  value       = aws_instance.control_plane.id
}

output "control_plane_public_ip" {
  description = "Admin access: SSH in as ec2-user with the private key matching var.ssh_public_key_path, fetch the kubeconfig (`cat /etc/rancher/k3s/k3s.yaml`), then replace its 127.0.0.1 with this IP before pointing kubectl/helm at it."
  value       = aws_instance.control_plane.public_ip
}

output "worker_instance_id" {
  value = aws_instance.worker.id
}

output "worker_public_ip" {
  description = "Where the app is actually reached. Use for the nip.io hostnames in a values-dev.yaml (e.g. api.<this-ip>.nip.io, app.<this-ip>.nip.io) and for curl verification."
  value       = aws_instance.worker.public_ip
}
