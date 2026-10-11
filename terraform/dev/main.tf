# Two EC2 instances running k3s (one "server" node acting as the control
# plane, one "agent" node running the actual workload) — no managed control
# plane, no NAT Gateway, no load balancer. Both sit in the same public
# subnet with public IPs, deliberately ephemeral (deploy, test, destroy)
# rather than long-lived.

data "aws_availability_zones" "available" {
  state = "available"
}

# Applied per-resource below (merged with each resource's own Name tag),
# not via provider-level default_tags — see providers.tf for why.
locals {
  common_tags = {
    Project     = "customer-insights"
    Environment = "dev"
    ManagedBy   = "terraform/dev"
  }
}

# Amazon Linux 2023, resolved via ec2:DescribeImages instead of the SSM
# public parameter this originally used — an org-level Service Control
# Policy denies ssm:GetParameter on AWS's public parameter namespace in
# this account, and this lookup never actually needed SSM in the first
# place. "al2023-ami-2023.*-x86_64" matches the standard (non-minimal)
# image, the same one the SSM parameter pointed at.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# 10.50.0.0/24, not 10.42.0.0/24: k3s's flannel defaults to 10.42.0.0/16 for
# the pod network (and 10.43.0.0/16 for Services) — the original VPC CIDR
# collided with that almost entirely. A pod's IP and its node's real ENI
# IP ended up looking like the same local subnet to the kernel's routing
# table, so replies to a pod from a Service's DNAT'd destination could
# route out the real ENI onto the VPC fabric instead of back over the
# cni0 bridge, and AWS silently drops them there (no matching instance at
# that IP) — a timeout, not a refused connection. Confirmed by curl
# succeeding instantly from the node's own netns but timing out from
# inside a pod on that same node, reproduced on two separate fresh
# instance pairs.
resource "aws_vpc" "this" {
  cidr_block           = "10.50.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = var.name })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.50.0.0/26"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, { Name = "${var.name}-public" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = var.name })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.common_tags, { Name = "${var.name}-public" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --- Security groups ---------------------------------------------------

resource "aws_security_group" "control_plane" {
  name        = "${var.name}-control-plane"
  description = "k3s server: API from the worker and the admin CIDR, SSH from both, nothing else inbound"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "k3s API (6443) from the worker node"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.public.cidr_block]
  }

  ingress {
    description = "k3s API (6443) for kubectl/helm from outside the cluster"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_admin_cidr]
  }

  ingress {
    description = "SSH for human access (kubeconfig fetch, run.sh)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_admin_cidr]
  }

  ingress {
    description = "SSH from the worker, to fetch the join token directly"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.public.cidr_block]
  }

  # flannel's VXLAN backend (its default) needs this between nodes. No
  # longer load-bearing now that the backend is host-gw (below), but kept
  # in case the backend is ever reverted.
  ingress {
    description = "flannel VXLAN (UDP 8472) from the worker"
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    cidr_blocks = [aws_subnet.public.cidr_block]
  }

  # host-gw (the current flannel backend) forwards pod traffic unmodified
  # between nodes instead of encapsulating it like VXLAN does — so a
  # cross-node pod-to-pod packet arrives here with a pod IP (flannel's
  # 10.42.0.0/16) as its source, never the worker's own 10.50.x.x host IP.
  # Without this, every such packet is silently dropped at the Security
  # Group layer: confirmed for real with a TCP connect straight to
  # coredns's pod IP timing out 100% of the time even though routing and
  # node-to-node connectivity on allowed ports were both fine.
  ingress {
    description = "pod-to-pod traffic from pods on the worker (flannel host-gw forwards unencapsulated)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.42.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.name}-control-plane" })
}

resource "aws_security_group" "worker" {
  name        = "${var.name}-worker"
  description = "k3s agent: kubelet from the control plane, HTTP/HTTPS open for ingress-nginx, no SSH in"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "flannel VXLAN (UDP 8472) from the control plane"
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    cidr_blocks = [aws_subnet.public.cidr_block]
  }

  # See the matching rule on aws_security_group.control_plane for why —
  # same host-gw unencapsulated-pod-IP reasoning, in the other direction.
  ingress {
    description = "pod-to-pod traffic from pods on the control plane (flannel host-gw forwards unencapsulated)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.42.0.0/16"]
  }

  ingress {
    description = "kubelet (10250) from the control plane"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.public.cidr_block]
  }

  ingress {
    description = "HTTP for ingress-nginx"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS for ingress-nginx (unused until TLS is added, opened for parity)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.name}-worker" })
}

# Human access to the control plane. SSM stays the preferred path if the
# account's permissions ever catch up — this is a fallback, not a
# redesign of how a human reaches the cluster.
resource "aws_key_pair" "node" {
  key_name   = "${var.name}-node"
  public_key = file(var.ssh_public_key_path)

  tags = merge(local.common_tags, { Name = "${var.name}-node" })
}

# Node-to-node key, separate from the human one above: lets the worker SSH
# into the control plane to fetch the k3s join token directly. Replaces an
# earlier SSM Parameter Store handoff — the instances' own IAM role could
# read/write that parameter fine, but an account-level Service Control
# Policy turned out to deny ssm:PutParameter on it too (confirmed by a
# real failed run, not assumed), so the whole SSM-based mechanism was
# dropped rather than chased further. No separate aws_key_pair/key_name
# for this — the worker never receives inbound SSH, it only ever
# initiates it, so the private key is just a file injected via user_data
# and the public key is appended to the control plane's authorized_keys
# the same way.
resource "tls_private_key" "node_to_node" {
  algorithm = "ED25519"
}

# A cluster placement group was tried here while chasing intermittent
# cross-node pod connectivity and removed again — AWS rejects it outright
# for t3.medium ("Cluster placement groups are not supported by the
# 't3.medium' instance type"). Not revisited since the other two fixes
# from that same investigation (host-gw backend, below; the UDP 8472
# Security Group rules) don't depend on it.

# Neither instance has an IAM role/instance profile at all anymore — once
# the join-token handoff above stopped using SSM, nothing left on either
# instance calls an AWS API, so there was nothing left for a role to
# grant. This also sidesteps every IAM permission gap hit earlier
# (TagInstanceProfile, UntagRole, RemoveRoleFromInstanceProfile) by
# removing the resources that needed them entirely.

# --- Instances -----------------------------------------------------------

resource "aws_instance" "control_plane" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.node.key_name
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.control_plane.id]
  associate_public_ip_address = true

  # Required for --flannel-backend=host-gw below: AWS drops any packet
  # whose source/destination doesn't match the ENI's own IP by default,
  # which is exactly what host-gw needs each node to do (forward packets
  # addressed to the *other* node's pod subnet). Without this, host-gw
  # would make cross-node connectivity worse, not better.
  source_dest_check = false

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  # Trusts the worker's node-to-node public key, so the worker can SSH in
  # later to fetch the join token directly.
  user_data = templatefile("${path.module}/user-data/control-plane.sh.tpl", {
    k3s_version     = var.k3s_version
    node_public_key = tls_private_key.node_to_node.public_key_openssh
  })

  tags = merge(local.common_tags, { Name = "${var.name}-control-plane" })
}

resource "aws_instance" "worker" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.worker.id]
  associate_public_ip_address = true

  # See the same setting on aws_instance.control_plane for why.
  source_dest_check = false

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  # Carries the node-to-node private key to SSH into the control plane
  # and fetch the join token directly — no SSM, no inbound SSH of its own.
  user_data = templatefile("${path.module}/user-data/worker.sh.tpl", {
    k3s_version      = var.k3s_version
    control_plane_ip = aws_instance.control_plane.private_ip
    node_private_key = tls_private_key.node_to_node.private_key_openssh
  })

  tags = merge(local.common_tags, { Name = "${var.name}-worker" })
}
