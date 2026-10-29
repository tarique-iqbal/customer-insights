# Debugging the Staging Tier (EKS)

Same spirit as `docs/dev/debugging.md` — explain the underlying concept before the fix, debug top-down by layer rather than guessing at the symptom's own layer — but several things that were self-managed on `terraform/dev`'s k3s are AWS-managed here, so the layers and the tools to inspect them both change. There's no `staging-deploy-verify` skill yet (the dev tier has `dev-deploy-verify`); this doc is the only write-up of this tier's debugging knowledge so far.

Every case below is a real, confirmed failure mode on this tier — verified against the live cluster, not guessed at.

## The mental model, adapted for a managed control plane

1. **Control plane** — AWS-managed. You don't SSH into it, and `kubectl` can't show you its internals directly.
2. **Node group** — AWS manages the Auto Scaling group and EC2 instances; Kubernetes still has its own view of node readiness, and the two can disagree.
3. **Platform** (`kube-system`) — different components than k3s: the VPC CNI (`aws-node`), not Flannel; the AWS Load Balancer Controller, not ingress-nginx.
4. **IRSA / OIDC trust** — a layer that doesn't exist on the dev tier at all, sitting between "Pod" and "can this Pod call AWS APIs."
5. **App** (`csat` namespace) — same as every other tier.
6. **Ingress/ALB** — AWS's own load balancer and target groups, with their own health-check lifecycle separate from Kubernetes'.

## Layer 1: control plane and node group

```bash
aws eks describe-cluster --name csat-staging --region ap-southeast-1 --query 'cluster.status'
aws eks describe-nodegroup --cluster-name csat-staging --nodegroup-name csat-staging-default \
  --region ap-southeast-1 --query 'nodegroup.{status:status,health:health}'
kubectl get nodes -o wide
```

**Concept you need**: AWS's view ("node group is `ACTIVE`") and Kubernetes' view ("node is `Ready`") are two different control systems that usually agree but aren't the same check — a node group can report healthy while an individual node is still joining, or vice versa. Check both before trusting either alone. If you suspect the control plane itself (not the nodes), its logs aren't reachable via `kubectl logs` at all — enable control-plane logging (`aws eks update-cluster-config --logging`) and read CloudWatch Logs instead.

## Layer 2: platform — now VPC CNI and the ALB Controller, not Flannel/ingress-nginx

```bash
kubectl get pods -n kube-system
```

Here this means `aws-node` (the VPC CNI DaemonSet — every Pod gets a real VPC-routable IP, replacing Flannel entirely), `kube-proxy`, `coredns`, the EBS CSI controller/node Pods, and `aws-load-balancer-controller`. Same principle as the dev tier: if `aws-node` itself is unhealthy on a node, every Pod scheduled there loses networking, which looks exactly like a scattered app-level failure — check this layer before the app, not after.

### Case: creating a resource failed on a `Tag*` call, not the resource itself

**Concept you need**: Terraform's AWS provider folds "create the resource" and "apply its tags" into one logical step for many resource types — if the account's IAM identity can create a resource type but not tag it, the whole operation fails, and the error message names the *create* API even though the specific denied call was the *tag* one.

**What happens**: `terraform apply` fails with `AccessDenied` on `iam:TagOpenIDConnectProvider` (creating the IRSA OIDC provider) and separately on `iam:TagPolicy` (creating the ALB Controller's IAM policy) whenever the applying identity's IAM policy grants *create* on a resource type but not *tag*. Don't take the error's own framing at face value — read the actual attached policy document to confirm which specific action is missing rather than assuming the named create API is simply denied outright.

**Fix**: removed the `tags` argument from exactly these two resources (`aws_iam_openid_connect_provider.eks`, `aws_iam_policy.alb_controller`) in `main.tf` — every other resource here keeps its tags, since their respective tagging actions (`iam:TagRole`, `ec2:CreateTags`, `eks:TagResource`) were all actually granted. The general lesson: when a create fails on a seemingly-unrelated `Tag*` permission, the fix is almost never "get more IAM permissions" in an account you don't control — it's "stop trying to tag that one resource type."

### Case: an orphaned IAM role blocks a fresh create

**Concept you need**: `terraform apply` creating a resource that already exists outside Terraform's state always fails with `EntityAlreadyExists` / `409` — Terraform has no way to know the resource is "the same one," so it refuses rather than guessing.

**What happens**: `aws_iam_role.node` (`csat-staging-node`) fails to create with a `409` whenever a role with that exact name already exists in AWS but isn't tracked in the current Terraform state — e.g. left over from an earlier, now-abandoned partial apply. If the identity running `apply` also has no `iam:DeleteRole`, deleting it outright isn't an option either.

**Fix**: `terraform import aws_iam_role.node csat-staging-node` — adopted the existing role into state instead of fighting for more permissions. This only works cleanly when the real resource's attributes already match what Terraform's config expects (confirmed first via `aws iam get-role`, comparing its `AssumeRolePolicyDocument` against the resource block before importing) — otherwise the next `plan` would show a diff Terraform might not have permission to reconcile either.

## Layer 3: IRSA/OIDC — the trust chain with no dev-tier equivalent

```bash
kubectl get sa aws-load-balancer-controller -n kube-system -o yaml | grep role-arn
aws iam get-role --role-name csat-staging-alb-controller --query 'Role.AssumeRolePolicyDocument'
```

**Concept you need**: a Pod doesn't get AWS permissions from its own spec — it gets them by presenting a Kubernetes ServiceAccount token that the EKS OIDC provider vouches for, which an IAM role's trust policy accepts (conditioned on that specific ServiceAccount's namespace/name via the `:sub` claim), which then grants whatever that role's attached policy allows. Four links, any of which can break independently: the ServiceAccount's `eks.amazonaws.com/role-arn` annotation, the OIDC provider existing and matching the cluster's actual issuer, the role's trust condition matching the right `:sub`, and the role's policy actually granting the needed action. If a controller Pod logs its own `AccessDenied` (not a Kubernetes-level error), this chain — not the Pod spec — is almost always where to look.

## Layer 4: the app itself

Same as every other tier — `kubectl get pods -n csat`, logs, exec. One incident here was shared with the dev tier, not EKS-specific:

### Case: the chart deployed into the wrong namespace, again

**Concept you need**: same root cause as `docs/dev/debugging.md`'s wrong-namespace case — `helm upgrade --install csat ...` with no `--namespace`/`-n` flag lands the release in `default` instead of refusing or warning.

**What happens**: `kubectl get pods -n csat` returns nothing, which looks like a failed deploy but isn't — `NAMESPACE: default` right in Helm's own install output is the giveaway, confirmed by `helm list -A` showing the release actually running elsewhere. This tier needs the `--namespace`/`-n` flag in **three places**, not one — the chart-deploy line, the `--destroy` path's `helm uninstall csat --kube-context "$CLUSTER_CONTEXT"`, and the post-deploy `kubectl get ingress csat` hostname check. A namespace-less `helm uninstall` silently fails to find a release that isn't in `default`, which leaves its ALB orphaned to block the VPC delete underneath it — the exact failure mode `run.sh`'s own comments already warn about. A namespace-less `kubectl get ingress` just as silently returns nothing instead of erroring, which looks like the Ingress never got a hostname rather than "looked in the wrong namespace."

**Fix**: add `--namespace csat --create-namespace` (or `-n csat`) to all three commands. Moving an already-misplaced release means `helm uninstall -n default` followed by a redeploy with the corrected flag — not an in-place move.

## Layer 5: Ingress/ALB — AWS's own health-check lifecycle

```bash
kubectl describe ingress csat -n csat
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
```

`describe ingress` surfaces the controller's own Events (target-group creation, attachment, health-check transitions) — check this before diving into the AWS console's Target Groups page.

### Case: `/healthz` failed right after the ALB got its hostname, then passed moments later

**Concept you need**: a Kubernetes Pod being `Ready` and an ALB target being marked `healthy` are two separate health-check systems on two different schedules. The ALB's target group runs its *own* periodic health check against each target IP (`target-type: ip` here routes straight to Pod IPs, skipping NodePort/kube-proxy entirely) with its own interval and healthy-threshold, starting fresh the moment a target registers — independent of however long that Pod had already been `Ready` in Kubernetes' own view.

**What happens**: right after a brand-new Ingress gets a real ALB hostname, the first endpoint checked can fail its retries for the first 30-60 seconds while endpoints checked later in the same verification sequence pass immediately — nothing is actually broken; whichever endpoint happens to be checked first simply lands inside the ALB's own target-registration warmup window, and the ones checked afterward don't.

**How to tell this apart from a real failure**: if a manual re-check (`curl` with the `Host:` header, no redeploy, no fix) succeeds shortly after a verification failure with nothing else having changed, suspect this race before anything else — especially right after a *brand-new* ALB/target-group is created (a redeploy reusing an existing, already-warm target group is much less likely to show it).

## Tearing this down: two failure modes that only show up on `terraform destroy`

Everything above happens on the way up. These two only happen on the way down, and both are structural — not a one-off leftover to clean up once, but something to expect on *every* destroy from this account's identity shape.

### Case: the ALB blocks the Internet Gateway detach

**Concept you need**: the AWS Load Balancer Controller creates the ALB via the Kubernetes API (reacting to the chart's `Ingress` object), not via a Terraform resource — so Terraform has no record of it and never deletes it. A plain `terraform destroy` still has to detach the VPC's Internet Gateway at some point, and AWS refuses that detach while anything in the VPC still holds a mapped public IP.

**What happens**: `terraform destroy` fails with `DependencyViolation: Network ... has some mapped public address(es)` on `aws_internet_gateway.this`, because the ALB's ENIs (one per AZ, each with a public IP) are still attached to the VPC's public subnets. `run.sh --destroy` avoids this by `helm uninstall`-ing the chart *before* touching Terraform at all, which lets the controller react to the `Ingress` deletion and clean up the ALB itself — but that only works if the node group (and therefore the controller Pod) is still running at that point. If the node group is already gone, there's no controller left to react, and the ALB has to be removed directly via `aws elbv2 delete-load-balancer`/the console instead.

**Fix**: confirm the ALB is actually gone (`aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='<vpc-id>']"` returns empty) before retrying the destroy — ALB deletion isn't instant, so a short wait and a re-check is often enough once nothing refers to it anymore.

### Case: this identity can never delete the IAM resources it creates

**Concept you need**: an IAM policy granting `iam:CreateRole`/`iam:AttachRolePolicy`/`iam:CreateOpenIDConnectProvider` etc. doesn't imply the matching `Detach*`/`Delete*` actions exist too — these are separate, independently-granted actions in AWS's IAM permission model, not a create/destroy pair that's granted or withheld together. Confirm which ones an identity actually has by reading its attached policy document directly, never by assuming symmetry. On this account's applying identity specifically: `ec2:*` and `eks:*` are both fully granted, but its attached policy has *zero* IAM detach/delete actions of any kind — an account-specific fact, not something every AWS account's policies do.

**What happens**: `terraform destroy` fails `iam:DetachRolePolicy` with `AccessDenied` on every IAM role this stack created (`cluster`, `node`, `ebs_csi`, `alb_controller`) and their policy attachments — 12 resources in total (4 roles, 1 policy, 1 OIDC provider, 6 attachments). Unlike the "orphaned IAM role" case under Layer 2 above (a leftover from one abandoned apply), this isn't something that happened once by accident — it happens on *every* destroy this identity ever runs, with no way around it short of a different identity.

**Fix**: `terraform state rm` all 12 IAM resources (untracks them only — no AWS API call, nothing is actually deleted), then `terraform destroy` again for whatever's left (the EKS cluster, VPC, subnets — all permitted under `ec2:*`/`eks:*`). The 12 resources stay orphaned in AWS afterward, costing nothing. Before the *next* `terraform apply` in this directory, re-import each one (`aws iam get-role`/`get-policy` first, to confirm it still matches `main.tf`'s config) — otherwise expect the same `409 EntityAlreadyExists` the orphaned-role case already covers, just for all 12 resources instead of 1.

## Quick reference

| Symptom | Check first | Covered above |
|---|---|---|
| Node group "healthy" in AWS, Pods not scheduling | `kubectl get nodes`, compare against `describe-nodegroup` | Layer 1 |
| Scattered Pod networking failures across a node | `kubectl get pods -n kube-system` — is `aws-node` healthy there | Layer 2 |
| `terraform apply` fails on a `Tag*` action | Remove `tags` from that one resource, don't chase more IAM permissions | Tag-create case |
| `terraform apply` fails with `409 EntityAlreadyExists` | `terraform import` the existing resource instead of fighting for delete permissions | Orphaned-role case |
| A controller Pod logs its own `AccessDenied` | Check the IRSA chain (ServiceAccount annotation → OIDC → role trust → role policy), not the Pod spec | Layer 3 |
| Pods "missing" from an expected namespace | `kubectl get ns`, `helm list -A` — same as the dev-tier case | Layer 4 |
| One endpoint fails right after a new ALB appears, passes on manual re-check moments later | Suspect ALB target-group warmup, not a real bug — re-check before changing anything | Layer 5 |
| `terraform destroy` fails detaching the Internet Gateway | Check for a still-live ALB with public ENIs in the VPC first | ALB-blocks-IGW case |
| `terraform destroy` fails `iam:DetachRolePolicy` on every IAM resource it created | `terraform state rm` them and destroy the rest; re-import before the next apply | Can't-delete-IAM case |

For the general cross-tier Helm/namespace/verification concepts (not EKS-specific), see `docs/dev/debugging.md` — this doc doesn't repeat what's already covered there.
