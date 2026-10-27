# AWS Resources (Staging Tier)

The staging tier is a managed EKS cluster, provisioned by `terraform/staging/`. Unlike `terraform/dev` (self-managed k3s, ephemeral, deploy → test → destroy), this tier exists to exercise what dev structurally can't: private nodes behind a NAT Gateway, a real AWS Load Balancer in front of the cluster, and IRSA (pod-level IAM). It also isn't meant to be destroyed after every session: EKS's control plane bills a flat ~$0.10/hr even sitting idle, unlike dev's pay-only-when-up EC2 pair, so there's no cost benefit to tearing it down between sessions the way dev's lifecycle does.

## Region and networking

This tier places nodes in **private subnets behind a NAT Gateway**, not in public subnets with no NAT the way `dev` does (which is also the cheaper shape, by roughly 1.5x in always-on cost). The deciding factor isn't cost: `dev` already covers "cheap, disposable, works on real AWS networking," so staging copying that same public-subnet/no-NAT shape would just pay the EKS control-plane fee a second time for an answer dev already gives. Staging's actual reason to exist — private nodes, a real load balancer in front of the cluster, IRSA — is exactly what dev's cheaper shape wouldn't exercise.

- **Region**: `ap-southeast-1`, same account/region as `terraform/dev` by default.
- **VPC**: `10.60.0.0/16` — chosen specifically to not overlap `terraform/dev`'s `10.50.0.0/24` or either CNI's default ranges. EKS's VPC CNI (below) assigns pods real VPC IPs, unlike k3s's Flannel overlay, so this tier actually needs real address space sized for pod count, not just node count.
- **Subnets**: 2 public (`10.60.0.0/20`, `10.60.16.0/20`) across 2 AZs — the NAT Gateway and the ALB live here — and 2 private (`10.60.32.0/20`, `10.60.48.0/20`) where the node group runs. EKS requires subnets in at least 2 AZs for the control plane regardless of where nodes end up.
- **NAT Gateway**: one, not one per AZ — this is staging, not a multi-AZ-HA-egress production build. A node in the AZ without the NAT still reaches it fine; that's cross-AZ traffic inside one VPC, not cross-region.
- **Subnet tags matter here in a way dev's don't**: `kubernetes.io/role/elb` on the public subnets and `kubernetes.io/role/internal-elb` on the private ones, plus `kubernetes.io/cluster/<name>: shared` on both, are how EKS and the AWS Load Balancer Controller auto-discover which subnets are candidates for an internet-facing vs. internal load balancer — without them, the ALB Controller has no way to know where to place one.

## No hand-rolled Security Groups

Unlike `terraform/dev/main.tf`, which defines two explicit Security Groups (control-plane, worker) with hand-picked rules, this file defines **none** — EKS creates and manages the cluster's own control-plane-to-node security group automatically once you give it subnet IDs. There's nothing here analogous to dev's `host-gw`/pod-CIDR Security Group rule, because the VPC CNI doesn't need one: pods get real VPC IPs directly, so there's no pod-IP-vs-host-IP mismatch at the Security Group layer to begin with. This is a real simplification, not an oversight — it's one of the structural differences a managed control plane buys you.

## IAM — four roles, two of them IRSA

- **`csat-staging-cluster`**: the control plane's own role (`AmazonEKSClusterPolicy`) — EKS assumes this to manage the cluster's AWS-side resources.
- **`csat-staging-node`**: the EC2 instance role for the managed node group's workers (`AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEKS_CNI_Policy`) — standard, not IRSA; every node in the group shares this one role.
- **`csat-staging-ebs-csi`** and **`csat-staging-alb-controller`**: **IRSA** roles — see below. Neither is attached to the node; both are assumed directly by a specific Kubernetes ServiceAccount via the OIDC provider.

## IRSA / OIDC — the layer with no dev-tier equivalent

**Concept**: a Pod doesn't inherit AWS permissions from the node it's running on here — it gets them by presenting its ServiceAccount's Kubernetes token to AWS, which the cluster's own OIDC provider vouches for, which an IAM role's trust policy accepts *only if* the token's `sub` claim names that exact namespace/ServiceAccount. Four links: the OIDC provider (`aws_iam_openid_connect_provider.eks`) existing and matching the cluster's real issuer URL; the role's trust policy condition on that issuer's `:sub`/`:aud`; the role's attached policy actually granting what's needed; and the ServiceAccount itself (created at Helm-install time, not by Terraform) carrying the `eks.amazonaws.com/role-arn` annotation pointing at the right role.

Two things use this here:
- **EBS CSI driver** (`aws_iam_role.ebs_csi`, trusting `system:serviceaccount:kube-system:ebs-csi-controller-sa`) — needed because EKS ships no default StorageClass or volume provisioner at all, unlike kind's local-path or k3s's built-in one. Without this add-on, the chart's `mysql` StatefulSet's PVC stays `Pending` forever.
- **AWS Load Balancer Controller** (`aws_iam_role.alb_controller`, trusting `system:serviceaccount:kube-system:aws-load-balancer-controller`) — its policy is vendored from the controller's own `v3.6.0` release JSON (`iam/alb-controller-policy.json`) rather than fetched at apply time, so a plan/apply doesn't depend on GitHub being reachable; re-fetch and diff before bumping the controller version.

## IAM identity requirements

Whatever IAM identity applies this Terraform needs `eks:*` at minimum — an identity that can create EC2/IAM resources but not EKS ones fails outright on `eks:CreateCluster`, not partway through. It would also need `iam:TagOpenIDConnectProvider` and `iam:TagPolicy` if the two tag-omissions in `main.tf` were ever reverted — as written, `main.tf` deliberately doesn't set `tags` on `aws_iam_openid_connect_provider.eks` or `aws_iam_policy.alb_controller`, specifically so neither action is required (see the comments on those two resources). The general pattern this follows — a missing `Tag*` action failing the whole create call, not just producing a follow-up warning — is covered in `docs/staging/debugging.md`.

## Known gaps, as of this doc's writing

- **No remote Terraform state backend** — flagged directly in `providers.tf`. Unlike `dev` (destroyed every session, so losing local state is low-stakes), this tier is meant to stay up, which makes local-only state a real risk once more than one person/machine touches it.
- **No Route53/real DNS** — the ALB is only reachable via its raw AWS-generated hostname plus a manual `Host:` header (see `docs/staging/kubernetes.md`).
- **`allowed_admin_cidr` defaults to `0.0.0.0/0`** (open), same convention as `terraform/dev/variables.tf` — narrow it in `terraform.tfvars` before relying on this for longer than a quick test.
