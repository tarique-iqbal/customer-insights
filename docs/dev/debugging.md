# Debugging the Dev Tier

This is a guide to *how* to debug `terraform/dev`'s real EC2/k3s cluster, not just a list of fixes — every section explains the underlying concept first, then the real incident that taught it. The condensed, repeatable version of the same checklist (for quickly running through a broken deploy) lives in `.claude/skills/dev-deploy-verify/SKILL.md`; this doc is the slower, "why does this even matter" companion to it.

Every incident below was silent or misleading at first — no error, or an error pointing at the wrong layer — which is itself the main lesson: **debug top-down, by layer, before trusting any symptom at the layer you first noticed it.**

## The mental model: four layers, checked in order

A request to this app crosses four layers, and a failure at any one of them can *look* identical from the outside (a timeout, a 500, a stuck Pod). Debugging fast means identifying which layer first, not guessing at the top:

1. **Infra** — do the EC2 instances exist, are they reachable, is the VPC/Security Group setup actually correct?
2. **Nodes** — did both k3s nodes join the cluster and go `Ready`?
3. **Platform** (`kube-system`) — is the cluster's own plumbing (CoreDNS, the CNI, the storage provisioner) healthy?
4. **App** (`csat` namespace) — are the application's own Pods healthy, and does the full request path actually work end to end?

Only once a layer is confirmed healthy is it safe to assume problems are coming from the layer above it. Jumping straight to "my app is broken" when the real fault is one layer down is how a missing node turns into chasing four unrelated-looking app bugs (see below).

## Always know which cluster you're talking to

Before any of the four layers, there's a layer zero: **is `kubectl` even pointed at the right cluster?**

```bash
kubectl config current-context
```

This repo has (at least) two separate clusters you might have a context for — `kind-csat` locally, and whatever `run.sh` generates for `terraform/dev` (`kubeconfig-dev.yaml`). If you haven't explicitly exported `KUBECONFIG` *in the terminal you're currently running commands in*, a bare `kubectl` can silently fall back to a different, stale, or empty context — and the result (`No resources found`, or a surprisingly small node count) looks exactly like a real cluster problem instead of a wrong-address problem.

```bash
export KUBECONFIG="$PWD/kubeconfig-dev.yaml"   # from terraform/dev/, after run.sh generates it
```

When in doubt, don't trust that the export persisted — pass `--kubeconfig=./kubeconfig-dev.yaml` explicitly on the command itself. This single check has saved more debugging time on this project than any other single habit, because every other symptom below becomes meaningless if you're actually looking at the wrong cluster.

## Layer 2: did both nodes actually join?

```bash
kubectl get nodes
```

**Concept**: a Kubernetes scheduler places Pods on whatever `Ready` nodes exist — it doesn't know or care that you *intended* to have two. If the worker never joined (a failed SSH handoff of the join token, a security group blocking it, etc.), every single Pod — the cluster's own `coredns`/`local-path-provisioner`/`metrics-server`, and all four app workloads — gets crammed onto the one node sized for the control plane alone.

**What that looks like from above**: scattered `CrashLoopBackOff` across pods that have nothing to do with each other, and `local-path-provisioner` failing PVC binds with `context deadline exceeded` — which reads like several unrelated app-level bugs. The actual cause is a single missing node causing resource contention. Always confirm **two** `Ready` nodes before debugging any individual Pod.

## Layer 3: is the platform itself healthy?

```bash
kubectl get pods -n kube-system
```

**Concept**: `kube-system` runs the cluster's own infrastructure — DNS (`coredns`), the volume provisioner (`local-path-provisioner`), and metrics (`metrics-server`). If *these* are unhealthy, nothing above them (your app) can be healthy either, no matter how correct your chart is. Checking this before touching your own workload answers "is this my bug, or the platform's?" in one command.

Two real incidents lived at exactly this layer, both on this project's real AWS networking (never reproduced in kind, which has no real inter-node network to misconfigure):

### Case: VPC CIDR collided with the pod network

**Concept you need**: a Kubernetes cluster has (at least) two separate IP address spaces layered on top of each other — the cloud network's own addressing (here, the VPC's `10.x.x.x` range) and the CNI's pod network (flannel's default `10.42.0.0/16`) plus the Service network (`10.43.0.0/16`). These ranges must never overlap, or the host OS's own routing table can't tell a pod IP from a real network-interface IP.

**What happened**: the VPC was originally `10.42.0.0/24` — overlapping flannel's pod range almost entirely. A pod's IP and its node's real ENI IP ended up looking like the same local subnet to the kernel, so a Service's DNAT'd reply could route out the real network interface onto the VPC fabric instead of back over the pod bridge (`cni0`) — and AWS silently drops a packet addressed to an IP no real interface owns. The result is a timeout, not a clean "connection refused," which is what made it so easy to mistake for flakiness rather than a deterministic misconfiguration. Confirmed by `curl` succeeding instantly from a node's own network namespace but timing out from inside a pod on that same node — reproduced identically on two separate fresh instance pairs, which is what proved it was a CIDR choice, not chance.

**Fix**: moved the VPC to `10.50.0.0/24`, well clear of both `10.42.0.0/16` and `10.43.0.0/16`. Never move it back into either range.

### Case: `host-gw` needs an explicit Security Group hole for the pod network

**Concept you need**: flannel (the CNI this cluster uses) has multiple backends for how it ships a packet from a pod on one node to a pod on another. **VXLAN** (the default) wraps the whole packet inside a UDP packet addressed between the two *nodes'* real IPs — the cloud network never sees a pod IP at all. **`host-gw`** instead just uses plain IP routing: the packet keeps the pod's own IP as its source/destination the entire way, which is faster and simpler, but only works when the nodes share a real L2 network (true here — same subnet).

**What happened**: VXLAN showed its own milder intermittent cross-node flakiness, so the backend was switched to `host-gw` to fix it. But because `host-gw` never encapsulates, a cross-node pod-to-pod packet arrives at the *receiving* node's Security Group still carrying a pod IP (`10.42.x.x`) as its source — never the sending node's own host IP. VXLAN's encapsulation had made this invisible, since every packet it ever sent used real node IPs. Without a rule for the pod CIDR, every such packet is silently dropped at the SG layer — confirmed by a TCP connect straight to CoreDNS's pod IP timing out 100% of the time, even while ordinary node-to-node traffic on allowed ports kept working perfectly fine. **That split — host-to-host fine, pod-to-pod dead — is the diagnostic tell for this exact problem.**

**Fix**: both Security Groups now have an explicit `10.42.0.0/16` ingress rule, and both instances set `source_dest_check = false` (AWS drops, by default, any packet whose source/destination doesn't match the ENI's own IP — exactly what `host-gw` requires each node to override, since it needs to forward packets addressed to the *other* node's pod subnet).

### How to test cross-node pod connectivity directly, without fooling yourself

**Concept you need**: a Pod with `hostNetwork: true` doesn't get a real pod IP from the CNI bridge (`cni0`) — it uses the node's own IP directly. That makes it useless for testing anything CNI/pod-network-specific, because it bypasses the exact layer you're trying to test.

```bash
kubectl run netdebug --image=curlimages/curl --restart=Never \
  --overrides='{"spec":{"nodeName":"<worker-or-cp-node-name>"}}' -- sleep 3600
kubectl exec netdebug -- nc -zv -w3 <other-node-pod-ip> <port>
```

Pinning an *ordinary* pod to a specific node with `nodeName` gives it a real `cni0`-assigned pod IP, which is the only way to actually exercise the pod-to-pod path end to end.

### Case: NetworkPolicy silently blocking what used to work

**Concept you need**: a `NetworkPolicy` is an allow-list, not a firewall rule you can reason about in isolation — once *any* policy selects a Pod for a direction (ingress or egress), every connection in that direction is denied unless some policy explicitly allows it. Unlike the CIDR/Security-Group cases above (which are AWS-level and affect every tier that shares the same VPC/SG config), this is Kubernetes-level and only actually *does* anything on this tier — k3s ships a kube-router-based policy controller enabled by default, enforcing exactly what the chart's `NetworkPolicy` objects (`kubernetes/chart/templates/{backend,nginx,frontend,mysql}/networkpolicy.yaml`, full rules in `docs/helm.md`) declare. kind's default CNI has no such controller, so the identical objects there are accepted but silently do nothing — which is exactly why this failure mode can't be reproduced or ruled out in kind.

**What it looks like**: a `nc`/`curl` from one Pod to another times out or refuses, even though nodes are `Ready`, `kube-system` is healthy, and the CIDR/Security-Group rules above are all correct — i.e., every earlier check in this doc passes, but the connection still doesn't work. The tell that distinguishes this from the Security-Group case: the Security-Group/host-gw failure is deterministic and total (100% of cross-node pod traffic, always), while a `NetworkPolicy` gap is specific to *which two workloads* are talking — same-node traffic between an allowed pair works fine, but a specific pair (or a pair missing an expected label) fails consistently.

**How to check directly**:

```bash
kubectl get networkpolicy -n csat
kubectl describe networkpolicy <name> -n csat
```

Then prove it rather than guess: an unlabeled debug Pod should fail to reach `mysql`, and one labeled `app: php` should succeed —

```bash
kubectl run netdebug --image=curlimages/curl --restart=Never -n csat -- sleep 3600
kubectl exec netdebug -n csat -- nc -zv -w3 mysql 3306   # expect: fails, no matching label

kubectl run netdebug-php --image=curlimages/curl --restart=Never -n csat \
  --overrides='{"metadata":{"labels":{"app":"php"}}}' -- sleep 3600
kubectl exec netdebug-php -n csat -- nc -zv -w3 mysql 3306   # expect: succeeds
```

If both behave as expected, the policy is working as designed — the real bug (if there is one) is almost always a missing label on whatever Pod needed to be let in (the `migrate` Job needing an explicit `app: migrate` label is exactly this kind of gap, found and fixed when these policies were first added), not the policy itself.

## Layer 4: the app itself

Two more incidents live here — not platform bugs, but the chart's own behavior under real conditions kind never exposes.

### Case: nginx stuck at `Init:0/1` — a DNS timing bug, not a DNS outage

**Concept you need**: most DNS clients resolve a hostname fresh on every connection. nginx's `fastcgi_pass php:9000;` does **not** — nginx resolves that hostname **once, synchronously, at config-load time**, and never retries on its own afterward. If the DNS answer simply isn't ready yet at that exact instant (not actually broken — just not propagated yet), nginx crash-loops permanently, because there's no later retry to save it.

**Fix in this chart**: a `busybox` initContainer (`kubernetes/chart/templates/nginx/deployment.yaml:35-41`) polls `nslookup php.default.svc.cluster.local.` in a loop until it succeeds, before the real nginx container ever starts — turning a one-shot race into a retry loop.

**The trap when reading this symptom**: `kubectl logs <pod> -c wait-for-php-dns` showing a steady "waiting for php to resolve" means the initContainer is working exactly as designed — it is **not** evidence of a DNS outage. The far more common real cause, especially if `nginx` landed on a different node than `php`, is the Layer-3 network path (see the `host-gw`/CIDR cases above), not DNS or nginx at all. Once the actual network issue is fixed, this initContainer recovers **on its own** — no restart, no redeploy — because it's still polling the whole time.

### Case: migrations silently "never ran" — a Helm hooks ordering gotcha

**Concept you need**: Helm's `post-install`/`post-upgrade` hooks (here, the `migrate` Job, `kubernetes/chart/templates/backend/migrate-job.yaml`) only fire *after* `--wait` confirms the main release's resources are actually ready. If that `--wait` fails for **any** reason — the nginx DNS race above, a slow image pull, anything — Helm never reaches the hook stage at all.

**What that looks like**: `kubectl get jobs` shows *nothing* — not a failed Job, not a stuck one, genuinely no trace, because it never started. This reads exactly like "the migration step is broken," but the actual fault is almost always one layer below it.

**Fix**: resolve whatever made the earlier `--wait` fail, then simply **re-run the identical `helm upgrade --install` command** — no separate manual migration step is needed, since the hook fires normally once the main wait succeeds.

One more detail worth knowing so a *successful* run doesn't look suspicious either: the Job's `hook-delete-policy: before-hook-creation,hook-succeeded` means it deletes itself after succeeding — so `kubectl get jobs` showing nothing between deploys is actually the **normal, healthy** case. Only a *failed* run is deliberately left behind, so there's something for `kubectl logs` to inspect.

### Case: the chart deployed into the wrong namespace entirely

**Concept you need**: `helm upgrade --install <release> <chart>` with no `--namespace`/`-n` flag doesn't fail, warn, or refuse — it silently deploys into whatever namespace is *current* in your kubeconfig's context (typically `default`). A Helm chart only ends up in a specific namespace if something explicitly says so, either a `--namespace` flag at install time or a `Namespace` resource templated inside the chart itself. This chart has neither as a hard guarantee — it relies entirely on the caller passing `--namespace csat`.

**What happened**: `terraform/dev/run.sh`'s chart-deploy step (`helm upgrade --install csat ...`) never passed `--namespace csat --create-namespace`, unlike the `ingress-nginx` install right above it in the same script, which does. The result: `kubectl get pods -n csat` correctly reported `No resources found` — not because the deploy failed, but because the whole release was actually sitting in `default` the entire time. The giveaway: `kubectl get ns` showed no `csat` namespace at all, which immediately rules out "deployed but broken" and points at "deployed somewhere else" instead.

**Fix**: `run.sh` now passes `--namespace csat --create-namespace` explicitly, matching the convention `kind` deploys already use (`-n csat`). Moving an already-misplaced release isn't a `kubectl mv`-style operation — the fix is `helm uninstall` from the wrong namespace, then redeploy with the corrected flag.

**The general lesson**: when `kubectl get pods -n <expected-namespace>` comes back empty, always check `kubectl get ns` and `helm list -A` before assuming the deploy itself failed — an empty *expected* namespace and a genuinely failed deploy look identical from that one command alone, but have completely different fixes.

## Verify for real — "Running" and "helm reported success" both lie by omission

**Concept you need**: a Pod reaching `Running`/`Ready` only proves its container started and passed its liveness/readiness probes. It says nothing about whether the actual feature works — a probe checking `/healthz` tells you the PHP process is alive, not that it can reach MySQL, and Helm's own `--wait` succeeding only means the resources it's watching reached their expected state, not that a real HTTP request through the full path (ingress → nginx → php-fpm → MySQL) succeeds.

Both the DNS-race and the `host-gw` incidents above happened **after** Helm itself had already reported success on an earlier, unrelated deploy — proving that "Helm said it worked" and "it works" are genuinely different claims here, not just excessive caution.

```bash
WORKER_IP=$(terraform output -raw worker_public_ip)
curl -s -w '  HTTP %{http_code}\n' "http://api.$WORKER_IP.nip.io/healthz"
curl -s -w '  HTTP %{http_code}\n' "http://api.$WORKER_IP.nip.io/api/static-pages"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' "http://app.$WORKER_IP.nip.io/"
```

If `/healthz` (no DB dependency) returns `200` but `/api/static-pages` (DB-backed) doesn't, check whether the schema even exists before assuming an app bug — a fresh cluster or a missed migration can leave the database structurally empty, which looks like a server error but isn't a code bug at all:

```bash
kubectl exec mysql-0 -n csat -- mysql -ulocal -pdev csat -e "SHOW TABLES;"
```

## A metadata-service footgun, if you ever edit the boot scripts

**Concept you need**: AWS's EC2 instance metadata service has two versions. **IMDSv1** answers a plain unauthenticated `GET` directly. **IMDSv2** (enforced on this account) requires fetching a short-lived token first (`PUT .../api/token`) and passing it as a header on the actual metadata `GET` — a request without that token doesn't error, it **silently returns nothing**.

**What happened**: a plain `curl http://169.254.169.254/...` inside `user-data/*.sh.tpl` returned empty, which quietly turned `--tls-san "$PUBLIC_IP"` into a no-op — the TLS certificate still got issued successfully, just without covering the public IP, so the failure only surfaced much later as a TLS verification error somewhere else entirely.

**Fix going forward**: any metadata read in these scripts fetches an IMDSv2 token first, passes it as a header on the `GET`, and fails loudly (non-zero exit, explicit message) if the expected value still comes back empty — rather than silently proceeding with a blank value and letting the failure surface somewhere confusing downstream.

## Quick reference

| Symptom | Check first | Covered above |
|---|---|---|
| `No resources found` / wrong pod count | `kubectl config current-context` | Always know which cluster |
| Scattered, unrelated-looking `CrashLoopBackOff` | `kubectl get nodes` (both `Ready`?) | Layer 2 |
| `kube-system` pods unhealthy | Security Group pod-CIDR rule, VPC CIDR | Layer 3 cases |
| Cross-node connect times out, same-node works | `host-gw` SG rule, not a `hostNetwork` test pod | Layer 3 cases |
| Specific Pod pair can't connect, everything else about the network checks out | `kubectl get/describe networkpolicy`, check for a missing label | NetworkPolicy case |
| nginx stuck `Init:0/1` | `wait-for-php-dns` logs, then the network path, not DNS itself | DNS-wait case |
| `kubectl get jobs` shows nothing after a deploy | Was this `helm upgrade --install`'s `--wait` actually successful? | Helm hooks case |
| Pods "missing" from an expected namespace | `kubectl get ns`, `helm list -A` | Wrong-namespace case |
| Helm says success, app still broken | curl the real endpoints, don't trust `Running` | Verify for real |

For the condensed, step-by-step runbook version of all of this (no explanations, just the commands in order), see `.claude/skills/dev-deploy-verify/SKILL.md`.
