# Kubernetes (Staging Tier)

Once `terraform/staging/` provisions the EKS cluster (`docs/staging/aws.md`), `run.sh` (`docs/staging/terraform.md`) installs the AWS Load Balancer Controller and deploys this repo's actual application via the same Helm chart every other tier uses. This doc covers that Kubernetes layer — what's EKS-specific, and what's inherited unchanged from the chart itself.

## No control-plane install step at all

`terraform/dev` runs a `curl | sh` k3s install with several non-default flags (`--disable traefik`, `--tls-san`, `--flannel-backend=host-gw`). This tier has nothing analogous — EKS *is* the control plane; there's no install step, no flags to tune, and no certificate/TLS-SAN concern, since `aws eks update-kubeconfig` handles all of that for you.

## Networking: VPC CNI, not Flannel

Every Pod here gets a real, routable VPC IP directly from the AWS VPC CNI (`aws-node`, running as a DaemonSet in `kube-system`) — there's no overlay network, no pod-CIDR-vs-host-IP translation, and therefore none of the `host-gw`/Security-Group class of bug `docs/dev/kubernetes.md` documents for Flannel. That's a real simplification, not just a different implementation detail: a whole category of dev-tier incident (CIDR collision, the `host-gw` Security Group gap) structurally can't happen here, because there's no encapsulation layer for a Security Group rule to need accounting for in the first place.

## No ingress-nginx — the AWS Load Balancer Controller instead

`terraform/dev` installs ingress-nginx in bare-metal mode (`hostNetwork: true`) because there's no cloud load balancer wiring on a self-managed cluster. This tier has the opposite problem solved the opposite way: `run.sh` installs the **AWS Load Balancer Controller** via Helm, wired to the IRSA role `terraform/staging` created (`docs/staging/aws.md`'s IRSA section) via the `serviceAccount.annotations` set — and the chart's own `templates/ingress.yaml` sets `ingressClassName: alb` plus `alb.ingress.kubernetes.io/{scheme,target-type}` annotations in `values-staging.yaml`, rather than ingress-nginx's defaults. `target-type: ip` means the ALB routes straight to Pod IPs (only possible because the VPC CNI gives every Pod a real routable IP — this wouldn't work over Flannel) rather than via each node's NodePort.

## The chart: `values-staging.yaml`

Same chart every tier uses (`kubernetes/chart`); only the values file differs. This one's distinguishing features:

- **Placeholder hostnames that don't need to resolve**: `api.csat-staging.internal` / `app.csat-staging.internal`, unlike dev's `nip.io` trick. The reason is different timing, not a different need: dev's EC2 IP is known immediately from a Terraform output, so `nip.io` can embed it right away; the ALB's real DNS name isn't known until *after* the Ingress is actually applied (the controller provisions it). `curl -H "Host: ..."` against the ALB's own AWS-generated hostname proves the routing works without needing any of this to resolve for real — see `docs/staging/debugging.md` and the Verify section below. Pointing real DNS (Route53) at the ALB is a later, not-yet-done step.
- **In-cluster MySQL, no RDS** — same StatefulSet every tier uses, running as-is with no migration needed. Deliberate scoping, not an oversight: this tier exists to validate Kubernetes/AWS-networking behavior (private nodes, IRSA, a real ALB), and introducing a managed-database migration at the same time would conflate two separate pieces of work. `README.md`'s Roadmap Ahead currently lists RDS only under its Production step, not staging — a managed database is a later, separate decision. Same throwaway-credential spirit as `values-dev.yaml`, different password.
- **No `REPLACE_ME`-style substitution** — `run.sh` deploys this values file as-is, unlike dev's `sed` pass over `values-dev.yaml`.

## EBS CSI driver + a StorageClass `run.sh` still has to apply by hand

EKS ships no default StorageClass or volume provisioner at all — unlike kind's local-path or k3s's built-in one. Without both the EBS CSI add-on (Terraform's job, via IRSA — `docs/staging/aws.md`) *and* an actual default `gp3` StorageClass object (`run.sh`'s job — the add-on provides the provisioner, not the StorageClass itself), the chart's `mysql` StatefulSet's PVC stays `Pending` forever and `helm upgrade --wait` just hangs.

## Everything else is inherited from the chart, unchanged

The DNS-wait `initContainer` on nginx, the zero-downtime `preStop`/`RollingUpdate` settings, `PodDisruptionBudget`s using `maxUnavailable` not `minAvailable`, the `migrate` Job's Helm-hook-ordering gotcha — all documented once in `docs/helm.md`/`docs/dev/kubernetes.md` and apply here exactly as written, since it's the same templates. Not duplicated in this doc.

**One thing that does behave differently here**: a replacement Pod gets a new Pod IP (same as anywhere else), but since the ALB routes by `target-type: ip` straight to Pod IPs, the AWS Load Balancer Controller also has to deregister the old target and register the new one in the ALB's target group — automatic, but it's an extra moving part this tier has that kind/dev (routing through a Service/NodePort, not directly to Pod IPs) don't.

## NetworkPolicy: declared, not enforced, on this tier either

Same caveat `docs/helm.md`'s NetworkPolicy section already covers in full: the chart's per-workload `NetworkPolicy` objects render and apply here too, but the Amazon VPC CNI doesn't enforce them by default — that needs `ENABLE_NETWORK_POLICY=true` set on the `aws-node` DaemonSet (or Calico installed instead), neither of which `terraform/staging` does yet. Of the three tiers, only `terraform/dev`'s k3s actually enforces these right now.

## Verify for real, including one EKS-specific race

Same principle as every other tier: a Pod being `Ready` and `helm upgrade --wait` succeeding both mean "the resources reached their expected state," not "a real request through the full path actually works." `run.sh`'s own verification curls three endpoints through the ALB's real hostname with an explicit `Host:` header, same as described above.

One quirk specific to a brand-new ALB: its target group runs its *own* health check against each target, on its own schedule, independent of how long the Pod has already been `Ready` in Kubernetes' own view — so the very first endpoint checked right after a new Ingress gets its hostname can fail for the first 30-60 seconds while endpoints checked moments later pass immediately, with nothing actually broken. Full detail and how to tell this apart from a real failure is in `docs/staging/debugging.md`.
