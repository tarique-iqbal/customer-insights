# AWS Resources (Dev Tier)

The dev tier is two real EC2 instances running self-managed k3s, provisioned by `terraform/dev/`. It's deliberately ephemeral — deploy, test, destroy within a single session — distinct from the local kind cluster (no AWS at all) and the future self-hosted-EKS staging tier (managed control plane). Every resource below exists either because the app needs it or because a real failure on this exact setup forced it; both kinds are called out.

## Region and AMI

- **Region**: `ap-southeast-1` (`variables.tf:1-5`), overridable — Free-Tier eligibility varies by region/account age, so this is noted rather than assumed.
- **AMI**: Amazon Linux 2023, resolved via `aws_ami`/`ec2:DescribeImages` (`main.tf:27-45`), not the SSM public parameter that normally serves this lookup. **Why**: an org-level Service Control Policy denies `ssm:GetParameter` on AWS's own public parameter namespace in this account — confirmed by a real failed `terraform plan`, not assumed in advance. The `DescribeImages` filter (`al2023-ami-2023.*-x86_64`) targets the same standard (non-minimal) image the SSM parameter would have pointed at.

## Networking

**VPC**: `10.50.0.0/24`, not `10.42.0.0/24` (`main.tf:58-64`). k3s's flannel defaults to `10.42.0.0/16` for the pod network and `10.43.0.0/16` for Services — the original VPC CIDR collided with the pod range almost entirely. **Behavioral insight**: a pod's IP and its node's real ENI IP ended up looking like the same local subnet to the kernel's routing table, so a Service's DNAT'd reply to a pod could route out the real ENI onto the VPC fabric instead of back over the `cni0` bridge — AWS silently drops it there (no instance owns that IP), producing a timeout, not a refused connection. Confirmed by `curl` succeeding instantly from a node's own network namespace but timing out from inside a pod on that same node, reproduced on two separate fresh instance pairs before the CIDR was moved.

**Subnet**: single public subnet, `10.50.0.0/26`, both instances in it (`main.tf:66-73`) — no private subnet/NAT, since there's no workload here that needs to be unreachable from the internet and a NAT Gateway bills hourly for no benefit in an ephemeral environment.

**Internet Gateway + route table**: standard `0.0.0.0/0` route (`main.tf:75-95`) — both instances get public IPs directly (`associate_public_ip_address = true`), which is the explicit tradeoff this tier makes for cost/simplicity over the bastion-and-private-subnet shape a longer-lived environment would use.

## Security Groups

Two SGs, one per node role, not one shared group — real segmentation, not just naming:

| SG | Port | Source | Why |
|---|---|---|---|
| `control_plane` | 6443/tcp | subnet CIDR | worker joining/talking to the k3s API |
| `control_plane` | 6443/tcp | `var.allowed_admin_cidr` | `kubectl`/`helm` from outside the cluster |
| `control_plane` | 22/tcp | `var.allowed_admin_cidr` | human SSH (kubeconfig fetch, `run.sh`) |
| `control_plane` | 22/tcp | subnet CIDR | worker SSHes in to fetch the join token (see Keys below) |
| `control_plane`, `worker` | 8472/udp | subnet CIDR | flannel VXLAN backend — kept even though host-gw is active now, in case the backend is ever reverted |
| `control_plane`, `worker` | all ports/protocols | `10.42.0.0/16` (pod CIDR) | **behavioral fix**, see below |
| `worker` | 10250/tcp | subnet CIDR | kubelet, reached from the control plane |
| `worker` | 80/tcp, 443/tcp | `0.0.0.0/0` | public app traffic via ingress-nginx |

The pod-CIDR rule is the direct consequence of a real incident: flannel was switched from VXLAN (the default, which showed its own milder intermittent cross-node flakiness) to `host-gw` to fix that — but host-gw forwards pod-to-pod packets **unencapsulated**, so a cross-node packet arrives at the Security Group carrying a pod IP (`10.42.x.x`) as its source, never the worker's own `10.50.x.x` host IP. VXLAN's encapsulation had made this invisible, since it always used real node IPs. Without this rule, every such packet is silently dropped at the SG layer — confirmed by a TCP connect straight to CoreDNS's pod IP timing out 100% of the time, even with node-to-node connectivity on allowed ports working fine.

**`source_dest_check = false`** on both instances (`main.tf:284`, `310`) is the other half of the same host-gw requirement: AWS drops any packet whose source/destination doesn't match the ENI's own IP by default, which is exactly what host-gw needs each node to do (forward packets addressed to the *other* node's pod subnet). Without this, host-gw would make cross-node connectivity worse, not better.

`allowed_admin_cidr` defaults to `0.0.0.0/0` (`variables.tf:13-17`) but is meant to be narrowed to your own `/32` in `terraform.tfvars` (gitignored, local-only). It flows straight into the `cidr_blocks` of two ingress rules on `aws_security_group.control_plane` — TCP 6443 (the k3s API, for `kubectl`/`helm`) and TCP 22 (SSH, for the kubeconfig fetch and `run.sh`) — so narrowing it to `"<your-ip>/32"` means only that exact source IP can reach either port, instead of the whole internet.

**The "stale IP" gotcha**: this is a static value, not auto-detected. If your ISP assigns a new public IP (common on home broadband, or switching networks/VPNs), this CIDR goes stale — you'd get a silent connection timeout on 22/6443 at the Security Group layer, not an AWS error. Fix: check your current IP (`curl -s ifconfig.me`), update `terraform.tfvars`, and `terraform apply` again to push the new rule.

## Instances

- **Type**: `t3.medium`, not the Free-Tier-eligible `t2.micro` it started on (`variables.tf:7-11`). **Behavioral insight**: `t2.micro`'s ~1GiB RAM OOMKilled MySQL mid-InnoDB-init (exit 137) — 8.0's real startup footprint needs more than that regardless of how the Pod's own memory limit is tuned (see `kubernetes/chart/values-dev.yaml`'s `mysql.resources` comment). `t3.medium` has the headroom for this, at the cost of no longer being Free-Tier-eligible — it bills by the hour, which is why `run.sh` defaults to leaving the environment up only until you explicitly ask it to `--destroy`, rather than nagging you every run.
- **Storage**: `gp3`, 8GiB, encrypted (`main.tf:286-290`, `312-316`) — encryption costs nothing extra on gp3 and there's no reason not to default it on.
- **IAM**: neither instance has an instance profile at all (`main.tf:262-267`). Originally one existed for the SSM-based join-token handoff; once that was dropped (see Keys below), nothing on either instance calls an AWS API, so there's nothing left for a role to grant. This also sidesteps every IAM permission gap hit while that role existed (`TagInstanceProfile`, `UntagRole`, `RemoveRoleFromInstanceProfile`) by removing the resources that needed them entirely, rather than chasing more permissions.

## Keys

Two separate key pairs, for two separate purposes:

- **Human access** (`aws_key_pair.node`, `main.tf:233-238`): your own public key (`var.ssh_public_key_path`), imported so you can SSH into the control plane for kubeconfig fetch / debugging. SSM stays the preferred path if the account's permissions ever catch up — this is a fallback, not a redesign.
- **Node-to-node** (`tls_private_key.node_to_node`, `main.tf:251-253`): a Terraform-generated ED25519 key, used only so the worker can SSH into the control plane and fetch the k3s join token directly:
  1. Terraform generates the key pair; the control plane trusts the public half (appended to `authorized_keys` at boot), the worker carries the private half.
  2. The worker SSHes into the control plane using that private key.
  3. Over that SSH session, it fetches the join token (`sudo cat /var/lib/rancher/k3s/server/node-token`).
  4. It installs k3s as an agent using that token, joining the cluster.

  **Behavioral insight**: this replaces an earlier SSM Parameter Store handoff — the instances' own IAM role could read/write that parameter fine, but the same account-level Service Control Policy that blocks `ssm:GetParameter` on the public AMI namespace turned out to also deny `ssm:PutParameter` on the account-owned parameter path, confirmed by a real failed apply. Rather than chase SSM further, the whole mechanism was dropped for direct SSH: the worker never receives inbound SSH of its own (no SG rule allows it), it only ever initiates it.

This private key lives in Terraform state as plaintext (it's a `tls_private_key` resource). State is a local file only (see `docs/dev/terraform.md`), so this is an accepted tradeoff for a throwaway lab environment, not something to carry into a longer-lived one unencrypted.

## Rejected approaches (kept here so they aren't retried)

- **Cluster placement group**: tried while chasing the intermittent cross-node connectivity above, removed again — AWS rejects it outright for `t3.medium` ("Cluster placement groups are not supported by the 't3.medium' instance type"). Not revisited, since the actual fixes (host-gw backend, the pod-CIDR SG rule) don't depend on it.
- **SSM for both the AMI lookup and the join-token handoff**: blocked twice by the same class of account-level Service Control Policy, on both the read and write side. Don't re-attempt either without checking whether that SCP has changed.
