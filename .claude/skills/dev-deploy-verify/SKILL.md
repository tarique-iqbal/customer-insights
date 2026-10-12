---
name: dev-deploy-verify
description: Deploy to or verify this repo's dev-tier environment — two real EC2 instances running self-managed k3s via terraform/dev, ephemeral (deploy, test, destroy) and distinct from both the local kind cluster and the future self-hosted-EKS staging tier. Use whenever the user asks to apply/run terraform/dev, deploy to the EC2 cluster, run run.sh, verify the dev k3s environment, or debug something that only reproduces on real AWS networking (cross-node pod connectivity, worker-join failures, DNS races) rather than in kind.
---

# Deploy to and verify the dev (EC2 k3s) environment

This environment broke in five distinct, non-obvious ways on its first real end-to-end run — every one of them silent (no error, or a misleading one) until actually inspected live. Full diagnostic narrative and the complete command log are in `notes/k8s-diagnose.md`; this skill is the condensed, repeatable checklist so the same investigations don't have to happen from scratch again.

## Step 0: the normal path is `run.sh`, not raw `terraform`/`helm`

```bash
cd terraform/dev
./run.sh            # apply -> wait for nodes -> install ingress-nginx -> deploy chart -> curl-verify -> leaves it up
./run.sh --destroy  # same, but tears the environment down on exit (success, failure, or Ctrl-C)
```

Only drop to raw `terraform apply`/`helm upgrade` when you're iterating on the Terraform or the chart itself (Steps 2–6 below). Before any manual `terraform apply`, always `terraform fmt && terraform validate` first — several real failures here were AWS rejecting a plan outright (e.g. a placement group on `t3.medium`), and `validate` catches a decent fraction of those before they cost an apply cycle.

## Step 1: always set KUBECONFIG explicitly, every command, every terminal

```bash
export KUBECONFIG="$PWD/kubeconfig-dev.yaml"   # from terraform/dev/, after run.sh has generated it
```

This has produced real, confusing dead ends twice: a bare `kubectl get pods` silently fell back to the local `kind-csat` context (or returned `No resources found` against a stale/empty one) because `KUBECONFIG` wasn't actually exported in *that* terminal. If a command's output looks wrong — wrong node count, wrong pod set, suspiciously old resources — run `kubectl config current-context` before debugging anything else. When in doubt, pass `--kubeconfig=./kubeconfig-dev.yaml` explicitly instead of trusting `export` to have persisted.

## Step 2: after `terraform apply`, confirm BOTH nodes joined before trusting any pod status

```bash
kubectl get nodes
```

Must show **two** `Ready` nodes (`control-plane` and `worker`). If it shows only one, don't start debugging individual Pods yet — a worker that never joined forces k3s to schedule *everything* (its own `coredns`/`local-path-provisioner`/`metrics-server`, and all four app workloads) onto a single node sized for the control plane alone. The resulting resource contention looks exactly like scattered, unrelated app bugs (`CrashLoopBackOff` everywhere, `local-path-provisioner` failing PVC binds with `context deadline exceeded`) but the real cause is one missing node. Check the worker's join with a debug pod or (temporarily) SSH — see `notes/k8s-diagnose.md` §3 for how, since the worker has no inbound SSH by design and getting a key onto it forces a replacement.

## Step 3: if pods are failing systemically (not just your app), suspect the platform layer first

Before touching the chart, check whether `kube-system` is healthy too:

```bash
kubectl get pods -n kube-system
```

If `coredns`/`local-path-provisioner`/`metrics-server` are also crash-looping or pending, the problem isn't your app — it's one of:

- **VPC/pod-CIDR collision.** `main.tf`'s VPC must stay outside flannel's pod CIDR (`10.42.0.0/16`) and k3s's Service CIDR (`10.43.0.0/16`) — it currently uses `10.50.0.0/24`/`/26` specifically to avoid this. A pod IP and a node's real ENI IP looking like the same subnet to the kernel's routing table causes DNAT replies to route out the wrong interface and get silently dropped by AWS — a timeout, not a refused connection, and it reproduces identically on fresh instances since it's a CIDR choice, not flakiness. Don't ever move the VPC CIDR into either of those two ranges again.
- **host-gw + missing Security Group rule for the pod CIDR.** The flannel backend is `host-gw`, which forwards cross-node pod traffic *unencapsulated* — a packet between pods on different nodes carries pod IPs (`10.42.x.x`), never the nodes' own host IPs. Both Security Groups have an explicit `10.42.0.0/16` ingress rule for exactly this; if that rule is ever removed (e.g. "cleaning up" what looks like an overly-broad rule), cross-node pod-to-pod traffic goes to zero, 100% of the time, while host-to-host traffic on allowed ports keeps working fine — that split (host ok, pod traffic dead) is the tell. `source_dest_check = false` on both instances is the other half of this same requirement.
- **Testing cross-node pod connectivity directly**: don't use a `hostNetwork: true` debug pod — it uses the node's own IP, not a real pod IP from `cni0`, and gives a false negative/positive for anything pod-CIDR-specific. Use an ordinary pod pinned with `nodeName`:
  ```bash
  kubectl run netdebug --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"nodeName":"<worker-or-cp-node-name>"}}' -- sleep 3600
  kubectl exec netdebug -- nc -zv -w3 <other-node-pod-ip> <port>
  ```

## Step 4: nginx stuck at `Init:0/1`? Check the DNS-wait initContainer, but look one level deeper

```bash
kubectl logs <nginx-pod> -c wait-for-php-dns
```

A steady stream of `waiting for php to resolve` means the initContainer itself is working as designed (nginx only resolves its `fastcgi_pass` hostname once, synchronously, at config-load — this blocks startup until that's actually safe). But the initContainer logging forever almost always means the *real* problem is network path to `php`'s pod IP, not DNS or nginx — check Step 3 first, especially if `nginx` landed on a different node than `php`. Once the actual network fix lands, this initContainer recovers **on its own**, with no restart or redeploy needed — it's still polling in a loop the whole time.

## Step 5: verify for real, not just "helm reported success"

```bash
WORKER_IP=$(terraform output -raw worker_public_ip)   # from terraform/dev/
curl -s -w '  HTTP %{http_code}\n' "http://api.$WORKER_IP.nip.io/healthz"
curl -s -w '  HTTP %{http_code}\n' "http://api.$WORKER_IP.nip.io/api/static-pages"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' "http://app.$WORKER_IP.nip.io/"
```

If `/healthz` and the app root return `200` but anything DB-backed (`/api/static-pages`, `/csat/42`) 500s, check whether the schema actually exists before assuming an app bug:

```bash
kubectl exec mysql-0 -- mysql -ulocal -pdev csat -e "SHOW TABLES;"
```

## Step 6: the one Helm gotcha that has no error message at all

**A failed `helm upgrade --install` for *any* reason means its `post-install`/`post-upgrade` hooks silently never ran.** The `migrate` Job (`kubernetes/chart/templates/backend/migrate-job.yaml`) only fires after Helm's `--wait` confirms the main resources are ready — if that wait fails (e.g. `nginx` stuck per Step 4), Helm never reaches the hook stage, and `kubectl get jobs` shows nothing at all (not even a failed, left-behind Job — there's genuinely no trace). This looks exactly like "migrations are broken," but the fix is almost always: resolve whatever made the earlier `--wait` fail, then **re-run the identical `helm upgrade --install` command** — no separate manual migration step needed.

```bash
helm upgrade --install csat kubernetes/chart -f /tmp/csat-values-dev.rendered.yaml --wait --timeout 8m
```

## If you're editing `user-data/*.tpl` yourself

IMDSv2 is enforced on this account. A plain unauthenticated `curl http://169.254.169.254/...` doesn't error — it silently returns nothing, which previously turned `--tls-san "$PUBLIC_IP"` into a no-op with no indication anything was wrong. Always fetch a token first (`PUT .../api/token`) and pass it as a header on the metadata `GET`, and fail loudly (non-zero exit, clear message) if the expected value still comes back empty rather than proceeding with a blank value.
