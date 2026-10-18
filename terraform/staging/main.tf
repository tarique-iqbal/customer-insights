# Managed-control-plane alternative to terraform/dev's self-hosted k3s —
# EKS owns etcd/control-plane HA/version upgrades/cert rotation instead of
# us. Nodes sit in private subnets behind a NAT Gateway (Option B, see
# notes/aws-qna.md's node-placement Q&A), deliberately not a copy of dev's
# "no NAT, public IPs" tradeoff: the reason for this tier to exist
# alongside dev (which is staying) is to exercise the production-shaped
# pieces dev structurally can't — private nodes, a real load balancer in
# front of the cluster, and IRSA for pod-level AWS access.

data "aws_availability_zones" "available" {
  state = "available"
}

# Applied per-resource below, same convention as terraform/dev/main.tf.
locals {
  common_tags = {
    Project     = "customer-insights"
    Environment = "staging"
    ManagedBy   = "terraform/staging"
  }

  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# --- Network ----------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = var.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = var.name })
}

# Two public subnets (NAT Gateway + the ALB live here), two private (nodes
# live here) — EKS requires subnets in >=2 AZs for the control plane
# regardless of where the nodes themselves end up.
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  # kubernetes.io/role/elb tells the AWS Load Balancer Controller this
  # subnet is a candidate for an internet-facing ALB; the cluster tag lets
  # both it and EKS itself auto-discover these subnets without being told
  # explicitly every time.
  tags = merge(local.common_tags, {
    Name                                = "${var.name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"            = "1"
    "kubernetes.io/cluster/${var.name}" = "shared"
  })
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 2)
  availability_zone = local.azs[count.index]

  tags = merge(local.common_tags, {
    Name                                = "${var.name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"   = "1"
    "kubernetes.io/cluster/${var.name}" = "shared"
  })
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
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Single NAT Gateway, not one per AZ — this is staging, not a
# multi-AZ-HA-egress production build. One NAT is the whole point of
# Option B's cost tradeoff versus dev's zero-NAT design; a node in the AZ
# without the NAT still reaches it fine (cross-AZ traffic inside one VPC,
# not cross-region).
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, { Name = "${var.name}-nat" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(local.common_tags, { Name = var.name })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = merge(local.common_tags, { Name = "${var.name}-private" })
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- EKS cluster --------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${var.name}-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.name}-cluster" })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = [var.allowed_admin_cidr]
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]

  tags = local.common_tags
}

# --- OIDC / IRSA ---------------------------------------------------------
# Lets pods (the AWS Load Balancer Controller, below) assume an IAM role
# directly via a Kubernetes ServiceAccount, instead of inheriting whatever
# the node's own instance role can do. k3s-on-EC2 (terraform/dev) has no
# equivalent of this — it's one of the specific things this tier exists to
# exercise.

data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]

  tags = merge(local.common_tags, { Name = "${var.name}-eks-oidc" })
}

# --- Node group -----------------------------------------------------------

resource "aws_iam_role" "node" {
  name = "${var.name}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.name}-node" })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-default"
  node_role_arn   = aws_iam_role.node.arn
  # Private subnets only — Option B's defining choice: nodes have no
  # public IP, the ALB (public subnets, below) is the one internet-facing
  # thing in front of the cluster.
  subnet_ids     = aws_subnet.private[*].id
  instance_types = [var.node_instance_type]
  ami_type       = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_ecr,
    aws_iam_role_policy_attachment.node_cni,
  ]

  tags = merge(local.common_tags, { Name = "${var.name}-node" })
}

# --- EBS CSI driver ---------------------------------------------------
# Unlike kind (its own default local-path StorageClass) and dev (k3s ships
# one built in), EKS provisions no default StorageClass or volume
# provisioner at all — the chart's mysql StatefulSet relies on the
# cluster's default StorageClass for its PVC (see that template's own
# comment), so without this, the PVC stays Pending forever and MySQL never
# schedules. This add-on provides the provisioner; run.sh still has to
# apply an actual (default) StorageClass object for it, since the add-on
# itself doesn't create one.

resource "aws_iam_role" "ebs_csi" {
  name = "${var.name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.name}-ebs-csi" })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  # Needs somewhere to actually run its controller pods.
  depends_on = [aws_eks_node_group.this]

  tags = local.common_tags
}

# --- AWS Load Balancer Controller IAM role (IRSA) --------------------------
# The role and its trust policy are Terraform's job (AWS-side); the
# controller's Helm install itself (kube-system, ServiceAccount annotated
# with this role's ARN) is a deploy-time step — same split as dev's
# ingress-nginx install living in run.sh rather than in Terraform.

resource "aws_iam_policy" "alb_controller" {
  name = "${var.name}-alb-controller"
  # Vendored from the aws-load-balancer-controller v3.6.0 release's own
  # published policy (docs/install/iam_policy.json in that repo), fetched
  # once rather than read over the network at apply time, so a plan/apply
  # doesn't depend on GitHub being reachable. Re-fetch and diff against the
  # next controller version before upgrading it.
  policy = file("${path.module}/iam/alb-controller-policy.json")

  tags = local.common_tags
}

resource "aws_iam_role" "alb_controller" {
  name = "${var.name}-alb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.name}-alb-controller" })
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}
