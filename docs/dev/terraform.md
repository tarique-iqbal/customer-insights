# Terraform (Dev Tier)

`terraform/dev/` provisions and tears down the two-EC2-instance k3s environment described in `docs/dev/aws.md`. This doc covers the Terraform-specific mechanics: layout, state, variables, templating, and the orchestration script that wraps all of it — not the AWS resources themselves.

## File layout

| File | Purpose |
|---|---|
| `main.tf` | VPC, subnet, IGW, route table, Security Groups, keys, the two `aws_instance`s |
| `variables.tf` | every input, each with a description carrying its own rationale |
| `outputs.tf` | IPs/IDs needed by `run.sh` and by a human (kubeconfig fetch, nip.io hostnames) |
| `providers.tf` | provider versions, backend decision (see State below) |
| `terraform.tfvars.example` | tracked template — copy to `terraform.tfvars` and edit |
| `terraform.tfvars` | your actual values; gitignored, never committed |
| `.terraform.lock.hcl` | provider version lock, tracked so `terraform init` is reproducible |
| `user-data/{control-plane.sh.tpl,worker.sh.tpl}` | boot-time scripts, see Templating below |
| `run.sh` | the actual entry point — see Orchestration below |

## State

No remote backend, by design (`providers.tf:15-21`): the long-lived production Terraform (this repo's other, not-yet-built root module) needs shared, locked state because it's always-on. This one is created and destroyed within a single test session, so there's nothing to share across machines or protect with a lock — state lives as a local `.tfstate` file in this directory only.

**Gitignore policy** for this directory: `.terraform/`, `*.tfstate*`, `*.tfvars` (but not `*.tfvars.example`), `crash.log`, and `kubeconfig*.yaml` are all ignored at the repo root. `terraform.tfvars` is excluded because it typically contains your personal `allowed_admin_cidr` and a path into your home directory (`ssh_public_key_path`) — neither belongs in version control, and the `.example` file exists precisely so the real structure is still documented and tracked.

## Variables and tfvars

Every variable in `variables.tf` documents its own "why" in its `description` rather than relying on a separate doc staying in sync — worth reading directly rather than duplicating here, but the two most consequential defaults:

- `instance_type` defaults to `t3.medium`, not a Free-Tier type — see `docs/dev/aws.md`'s Instances section for the OOMKilled-MySQL reasoning behind that.
- `allowed_admin_cidr` defaults to `0.0.0.0/0` (open) — intentionally permissive out of the box since this is a throwaway environment, but the description says to narrow it, and `terraform.tfvars.example` repeats that as a comment so it isn't missed.

`name` (default `csat-dev`) prefixes every resource's `Name` tag, specifically so these resources are never visually confused with the separate, not-yet-built production Terraform root module.

## Templating user-data

`main.tf:294-297` and `320-324` pass version/IP/key values into `user-data/*.sh.tpl` via `templatefile()`, rather than hardcoding them into the scripts — this is what lets the same scripts serve any run of `terraform apply` without editing shell code by hand.

**If you edit a `user-data/*.sh.tpl` file yourself**: IMDSv2 is enforced on this account. A plain, unauthenticated `curl http://169.254.169.254/...` doesn't error — it silently returns nothing, which once turned `--tls-san "$PUBLIC_IP"` into a no-op with no indication anything was wrong, because the cert still got issued (just without covering the public IP). Both follow this pattern for any metadata read, rather than assuming a bare `curl` is safe:

1. Fetch a token first (`PUT .../api/token`).
2. Pass that token as a header on the metadata `GET`.
3. Fail loudly (non-zero exit, explicit message) if the expected value still comes back empty.

## Validate before apply

Run `terraform fmt && terraform validate` before any manual `terraform apply` — several real failures here were AWS rejecting a plan outright (e.g. the cluster-placement-group attempt noted in `docs/dev/aws.md`, which `t3.medium` doesn't support), and `validate` catches a decent fraction of those before they cost a full apply cycle.

## Orchestration: `run.sh`

The normal path is `./run.sh`, not raw `terraform apply`/`helm upgrade` by hand. It runs, in order:

1. `terraform init`
2. `terraform apply`
3. Wait for SSH on the control plane
4. Wait for k3s to write its kubeconfig
5. Fetch and rewrite that kubeconfig's `127.0.0.1` to the real public IP
6. Wait for both nodes `Ready`
7. Install ingress-nginx (bare-metal/hostNetwork mode, no cloud load balancer here)
8. Render `values-dev.yaml` (substituting the worker's real IP for `REPLACE_ME_WORKER_IP`)
9. `helm upgrade --install` the chart
10. Curl-verify three endpoints
11. Leave the environment running

**Default behavior is to leave the environment up on exit**, for any reason — success, a failed step, or Ctrl-C (`trap cleanup EXIT`, `run.sh:74-86`) — specifically so a failure mid-run doesn't also destroy the evidence needed to debug it. Passing `--destroy` makes teardown automatic on that same exit instead; without it, `terraform destroy` is something you run yourself when you're actually done, which also means you're responsible for not leaving a non-Free-Tier `t3.medium` pair running longer than you meant to.

`run.sh` also fails fast and explicitly rather than silently: it checks for `terraform`, `ssh`, `scp`, `kubectl`, `helm`, `curl` up front, and refuses to proceed without a `terraform.tfvars` file present, pointing you at `terraform.tfvars.example`.

See `docs/dev/kubernetes.md` for what happens on the Kubernetes/Helm side of this same run, and `.claude/skills/dev-deploy-verify/SKILL.md` for the full troubleshooting checklist if a run doesn't come up clean.
