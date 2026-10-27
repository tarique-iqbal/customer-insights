# Terraform (Staging Tier)

`terraform/staging/` provisions the EKS environment described in `docs/staging/aws.md`. This doc covers the Terraform-specific mechanics — layout, state, variables, orchestration — not the AWS resources themselves.

## File layout

| File | Purpose |
|---|---|
| `main.tf` | VPC, subnets, route tables, NAT, the EKS cluster + its IAM role, the OIDC provider, the node group + its IAM role, the EBS CSI add-on + its IRSA role, the ALB Controller's IRSA role |
| `variables.tf` | every input, each with a description carrying its own rationale |
| `outputs.tf` | values `run.sh` and a human both need (cluster name/endpoint, VPC/subnet IDs, the ALB Controller's role ARN) |
| `providers.tf` | provider versions, backend decision (see State below) |
| `terraform.tfvars.example` | tracked template — copy to `terraform.tfvars` and edit |
| `terraform.tfvars` | your actual values; gitignored, never committed |
| `iam/alb-controller-policy.json` | vendored AWS Load Balancer Controller IAM policy — see `docs/staging/aws.md`'s IRSA section |
| `run.sh` | the actual entry point — see Orchestration below |

## State

`providers.tf` flags this directly: no remote backend yet, same as `terraform/dev` for now — but the risk profile is different. Dev is destroyed every session, so losing its local state costs nothing. This tier is meant to stay running instead — EKS's control plane bills a flat ~$0.10/hr even idle, so there's no cost reason to tear it down between sessions the way dev's lifecycle does — which makes local-only state a real liability the moment more than one person or machine might apply against it, or if it's left running long enough that losing the state file would actually hurt. Add an S3 (+ DynamoDB, or S3 native locking on Terraform ≥1.10) backend before either of those becomes true.

## Variables and tfvars

Every variable in `variables.tf` documents its own "why" directly — worth reading rather than duplicating here, but the choices worth calling out:

- `vpc_cidr` defaults to `10.60.0.0/16`, deliberately chosen to not collide with `terraform/dev`'s `10.50.0.0/24` or either CNI's default ranges — see `docs/staging/aws.md`'s networking section for why this tier needs more real address space than dev did.
- `kubernetes_version` defaults to `1.31` — EKS deprecates old control-plane versions on its own schedule, so check `aws eks describe-addon-versions` or the console for the currently supported range before trusting this default blindly.
- `node_instance_type` defaults to `t3.medium` — deliberately reusing the same size `terraform/dev` settled on after its `t2.micro` OOMKill, rather than re-deriving a number from scratch.
- `node_desired_size` defaults to `2` (with `min_size: 1`, `max_size: 3`) specifically so the cluster survives one node's maintenance/replacement without dropping to zero capacity — dev's single-worker shape doesn't have this concern.
- `allowed_admin_cidr` defaults to `0.0.0.0/0`, same convention and same caveat as `terraform/dev/variables.tf`: narrow it in `terraform.tfvars` before relying on this past a quick test.

## No user-data templating

`terraform/dev` templates boot-time shell scripts (`user-data/*.sh.tpl`) into its EC2 instances via `templatefile()`. This tier has no equivalent at all — the managed node group handles node bootstrapping itself; there's no custom boot script to template, parameterize, or debug here.

## Validate before apply

Same discipline as `terraform/dev`: run `terraform fmt && terraform validate` before any manual `terraform apply`. The two tag-permission gaps found running this tier for real (see `docs/staging/debugging.md`) were only caught by an actual `apply`, not by `validate` — but `validate` still catches a decent fraction of mistakes (a malformed reference, a type mismatch) before they cost a full apply cycle, same as it does for dev.

## Orchestration: `run.sh`

The normal path is `./run.sh`, not raw `terraform apply`/`helm upgrade` by hand. It runs, in order:

1. `terraform init`
2. `terraform apply`
3. `aws eks update-kubeconfig` (no SSH involved, unlike dev's kubeconfig-fetch-over-SSH dance)
4. Wait for the node group's nodes to show `Ready`
5. Apply a default `gp3` StorageClass (the EBS CSI add-on provides the provisioner, not the StorageClass object itself)
6. Install the AWS Load Balancer Controller via Helm, wired to the IRSA role from the Terraform output
7. `helm upgrade --install` the chart, into the `csat` namespace
8. Poll the Ingress for its real ALB hostname
9. Curl-verify via a `Host:` header override against that hostname (no DNS points at the chart's placeholder hostnames — see `docs/staging/kubernetes.md`)
10. Leave the environment running

**Default behavior is the opposite of dev's**: this leaves the environment up on exit, for any reason — success, a failed step, or Ctrl-C (`trap cleanup EXIT`) — specifically because this tier isn't meant to be torn down after every session. Passing `--destroy` makes teardown automatic on that same exit instead. The destroy path does one thing dev's doesn't need to worry about: `helm uninstall`s the chart *before* `terraform destroy` touches the VPC, because the ALB Controller created a real load balancer outside Terraform's own view (Helm/the controller created it, not an `aws_lb` resource) — skipping that uninstall leaves an orphaned ALB that keeps billing and can make the VPC delete fail with "has dependent objects."

Same fail-fast discipline as dev's `run.sh` too: it checks for `terraform`/`aws`/`kubectl`/`helm`/`curl` up front, and refuses to proceed without a `terraform.tfvars` file present.

See `docs/staging/kubernetes.md` for what happens on the Kubernetes/Helm side of this same run, and `docs/staging/debugging.md` for the troubleshooting checklist if a run doesn't come up clean.
