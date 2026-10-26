# Kubernetes (Dev Tier)

Once `terraform/dev/` provisions the two EC2 instances (`docs/dev/aws.md`), `run.sh` (`docs/dev/terraform.md`) installs and verifies this repo's actual application on a real, self-managed k3s cluster. This doc covers that Kubernetes layer: how k3s itself is installed, how the same Helm chart used by kind gets a dev-specific values file, and the handful of behavioral fixes that only showed up on real AWS networking.

## k3s install

The control plane installs via `curl -sfL https://get.k3s.io | ... sh -s - server` with three non-default flags (`user-data/control-plane.sh.tpl:43-47`):

- `--disable traefik` — k3s bundles Traefik as its default ingress controller; this chart installs ingress-nginx instead (see below), so Traefik would just be two more Helm-install Jobs and a controller Pod competing for resources on an already-tight node, serving nothing.
- `--tls-san "$PUBLIC_IP"` — the kubeconfig's server certificate must cover whatever address `kubectl`/`helm` actually connect through. `run.sh` rewrites the kubeconfig's `127.0.0.1` to the control plane's real public IP after fetching it; without this flag that rewritten address would fail TLS verification.
- `--flannel-backend=host-gw` — see Networking below.

The worker joins via `K3S_URL`/`K3S_TOKEN` against the control plane, where the token itself is fetched over SSH rather than any AWS-native mechanism — see `docs/dev/aws.md`'s Keys section for why.

## Networking: host-gw and its Security Group cost

Flannel's default backend, VXLAN, showed its own milder intermittent cross-node pod connectivity failures on this setup. Switching to `--flannel-backend=host-gw` fixed that — it uses plain IP routing between nodes instead of UDP encapsulation, which works well when nodes share an L2 network (true here, same subnet) — but **host-gw forwards pod-to-pod packets unencapsulated**, so they arrive at the other node carrying a pod IP as their source, not the sending node's own host IP, unlike VXLAN. That's not a Kubernetes-level concern by itself, but it has a real AWS Security Group consequence (both SGs need an explicit rule for the pod CIDR, `source_dest_check` must be disabled) — fully covered in `docs/dev/aws.md`'s Security Groups section, not duplicated here since it's really one fix spanning both layers.

## Installing ingress-nginx

There's no AWS Load Balancer Controller or cloud-controller-manager wiring on this self-managed cluster, so a `LoadBalancer`-type Service would never get an external IP — `run.sh` installs ingress-nginx in bare-metal mode instead (`controller.hostNetwork=true`, `controller.service.type=ClusterIP`), binding directly to the worker node's host ports 80/443, which is exactly what the worker's Security Group opens to `0.0.0.0/0`.

`controller.admissionWebhooks.enabled=false` is set deliberately: that webhook's pre-install Job (cert generation, patching the `ValidatingWebhookConfiguration`) is a known source of hangs on a small/fresh single-node-at-a-time cluster, and the validation it provides isn't needed here — this is a throwaway test cluster deploying one already-correct `Ingress`, not a multi-tenant cluster where admission-time validation earns its keep.

## The chart: `values-dev.yaml`

The same Helm chart (`kubernetes/chart`) deploys to kind, the dev tier, and (eventually) staging — only the values file differs per tier. `values-dev.yaml`'s distinguishing features:

- **nip.io hostnames**: `api.<worker-ip>.nip.io` / `app.<worker-ip>.nip.io`, a wildcard-DNS service that resolves any `<ip>.nip.io` subdomain to that embedded IP with no DNS record to manage — necessary because, unlike kind's `localtest.me`, the worker's public IP is only known after `terraform apply` runs. `run.sh` substitutes the real IP in for the file's `REPLACE_ME_WORKER_IP` placeholder before deploying (`run.sh:133-134`).
- **Published image tags, not `:local`**: `backend.image`/`frontend.image` pin the same already-verified published SHAs `values-local.yaml` pins, since this cluster never builds images itself. `nginx.image` is still on `latest` as of this writing — not yet pinned to a verified SHA, since no dev or kind run has confirmed one specifically for nginx the way the other two images were confirmed.
- **MySQL resources, raised from kind's defaults**: `256Mi` was sized for a Free-Tier `t2.micro`'s ~1GiB total RAM, but OOMKilled MySQL mid-InnoDB-init (exit 137) — 8.0's real startup footprint needs more than that regardless of node size. That's the same incident that moved `terraform/dev/variables.tf`'s `instance_type` default to `t3.medium` (`docs/dev/aws.md`); the Pod limit was raised to `512Mi` to match.

## Behavioral fix: `wait-for-php-dns` initContainer

`nginx`'s `fastcgi_pass php:9000;` resolves the `php` hostname via in-cluster DNS — but nginx resolves that hostname **once, synchronously, at config-load time**, not per-request. A DNS lookup that's merely slow (not actually broken) at that exact instant crash-loops nginx permanently, since nginx never retries the resolution on its own. This was observed for real on this self-hosted k3s/EC2 environment even after cluster-level DNS was otherwise confirmed healthy and stable — kind and Compose never exhibit it, so the shared nginx image/config is untouched; the fix is chart-level only (`templates/nginx/deployment.yaml:35-41`): a `busybox` initContainer that polls `nslookup php.default.svc.cluster.local.` until it succeeds, before the real nginx container ever starts.

If a deployed nginx Pod is stuck at `Init:0/1`, check this initContainer's logs first (`kubectl logs <pod> -c wait-for-php-dns`) — a steady "waiting for php to resolve" means it's working as designed, and the real problem to chase is usually the network path to `php`'s pod IP (see Networking above), not DNS or nginx itself. Once that's fixed, the initContainer recovers on its own with no restart needed.

## Behavioral fix: zero-downtime rollout

`nginx`'s Deployment sets `strategy.rollingUpdate.maxSurge: 1, maxUnavailable: 0` (`templates/nginx/deployment.yaml:22-26`) and a `preStop` hook that sleeps 5 seconds before the container receives `SIGTERM` (`templates/nginx/deployment.yaml:56-59`). The hook exists because nginx stops accepting connections almost immediately on `SIGTERM`, which can race ahead of ingress-nginx/kube-proxy actually removing the terminating Pod from the Service's endpoint list — without the delay, a request can land on a Pod that's already stopped listening. This was verified against a live cluster, not assumed: a rollout dropped 3 requests out of 200 without the `preStop` delay, and 0 out of 200 with it.

## The hook that silently never runs

The `migrate` Job (`templates/backend/migrate-job.yaml`) is a `post-install,post-upgrade` Helm hook — it only fires after Helm's `--wait` confirms the main resources are ready. **If that wait fails for any reason** (e.g. nginx stuck per the DNS section above), Helm never reaches the hook stage at all, and `kubectl get jobs` shows nothing — not even a failed, left-behind Job, since it genuinely never started. This looks exactly like "migrations are broken" but isn't; the fix is to resolve whatever made the earlier `--wait` fail, then **re-run the identical `helm upgrade --install` command** — no separate manual migration step is needed, since the hook fires normally once the main wait succeeds.

The Job's own `hook-delete-policy: before-hook-creation,hook-succeeded` (`migrate-job.yaml:13`) is why a successful run never shows up in `kubectl get jobs` between deploys either — it deletes itself on success, and only a *failed* run is left behind (deliberately) for `kubectl logs`.

## NetworkPolicy: actually enforced here, unlike kind

The chart's per-workload `NetworkPolicy` objects (`templates/{backend,nginx,frontend,mysql}/networkpolicy.yaml` — full rules and reasoning in `docs/helm.md`) render and apply on every tier, but only do anything on this one. k3s ships a kube-router-based Network Policy controller enabled by default, alongside Flannel — Flannel itself only handles routing, kube-router is what actually reads these objects and enforces them via iptables. kind's default CNI (kindnet, a Flannel fork) has no such controller, so the identical objects are accepted there but inert.

Practically, this means a connectivity problem on this tier that would be impossible in kind — a Pod that should reach another one timing out even though nodes, DNS, and the network path (per the Networking section above) are all otherwise healthy — can now also be a `NetworkPolicy` blocking it, not just the CIDR/Security-Group issues this doc already covers. See `docs/dev/debugging.md`'s NetworkPolicy case for how to tell the two apart.

## PodDisruptionBudgets: `maxUnavailable`, not `minAvailable`

Each workload's PDB uses `maxUnavailable: 1` rather than `minAvailable: 1` (e.g. `templates/backend/pdb.yaml`). These Deployments idle at 1 replica (the HPA's `minReplicas`) — `minAvailable: 1` would block every voluntary disruption (a node drain, for instance) forever at that resting state, since going to 0 replicas even momentarily would violate it. `maxUnavailable: 1` is a no-op at 1 replica (nothing better is achievable there anyway) but genuinely protects once the HPA has scaled out under load, which is the condition it's actually meant for.

## Verify for real, not just "helm reported success"

`run.sh`'s final step curls three endpoints — `/healthz`, `/api/static-pages` (DB-backed), and the web app root — and treats a non-matching HTTP status as a hard failure (`run.sh:139-162`), rather than trusting Helm's own `--wait` success. A Pod reaching `Running`/`Ready` only proves the container started and passed its probes, not that the whole request path (ingress → nginx → php-fpm → MySQL) actually works end to end — the DNS-race and host-gw incidents above both happened well after Helm itself reported success.

For the full command-by-command troubleshooting checklist (confirming both nodes joined, testing cross-node pod connectivity without a false-negative-prone `hostNetwork` debug pod, etc.), see `.claude/skills/dev-deploy-verify/SKILL.md` — it's written as a repeatable runbook rather than prose, so it isn't duplicated here.
