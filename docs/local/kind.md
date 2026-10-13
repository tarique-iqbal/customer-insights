# Kubernetes (Local, kind)

The local tier runs the same Helm chart as every other tier (`docs/helm.md`) on a [kind](https://kind.sigs.k8s.io/) cluster — Kubernetes-in-Docker, entirely on your own machine, no cloud account involved. This doc covers what's specific to running it locally: cluster setup, the two cluster-level add-ons the chart itself doesn't install, and the day-to-day deploy/verify workflow. Chart-wide conventions (values tiering, hooks, probes, PDBs) live in `docs/helm.md`; the EC2 dev tier's equivalent is `docs/dev/kubernetes.md`.

## Cluster setup

`kubernetes/kind-config.yaml` defines a single-node cluster (release name `csat`) set up for kind's own documented ingress recipe:

- `kubeletExtraArgs: node-labels: "ingress-ready=true"` — the label ingress-nginx's kind-specific manifest selects on to schedule its controller.
- `extraPortMappings` for container ports 80/443 → host ports 80/443 — this is what lets `curl http://api.localtest.me/...` from your own machine reach the cluster at all; without it, the Ingress would only be reachable from inside the kind Docker network.

Create the cluster with:

```bash
kind create cluster --config kubernetes/kind-config.yaml
```

## Two add-ons the chart doesn't install

Unlike the dev tier, where `run.sh` installs ingress-nginx as part of the same script that deploys the app (`docs/dev/terraform.md`), kind's ingress-nginx and metrics-server are installed **separately, by hand**, once per cluster — `values-local.yaml`'s header comment states this explicitly so it isn't mistaken for something the chart itself should be doing:

```bash
# ingress-nginx, kind's own provider-specific manifest (binds the hostPort
# mapping above, not a cloud load balancer):
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# metrics-server, needed for the chart's HPAs to have anything to scale on:
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

The `--kubelet-insecure-tls` patch is **kind-specific** — kind's kubelet certs fail metrics-server's default TLS verification, and that patch is how to get past it in this one environment. Don't carry that flag into a real cluster; a cloud tier has valid kubelet certs and the patch would just be silently papering over a certificate problem that's worth knowing about there.

## What `values-local.yaml` overrides

`values-local.yaml`'s own header comment (lines 1-5) names the two add-ons above and confirms Services stay `ClusterIP` (the chart's own default) — the Ingress is how everything is actually reached, not a `NodePort`/`LoadBalancer` Service. Beyond that, it overrides:

- **`*.localtest.me` hostnames** (`api.localtest.me`, `app.localtest.me`) — a public DNS wildcard that resolves to `127.0.0.1`, so this needs no `/etc/hosts` edit on your machine. The dev tier's equivalent is `*.nip.io` resolving to the worker's real public IP instead (`docs/dev/kubernetes.md`), since `127.0.0.1` wouldn't mean anything there.
- **Autoscaling enabled** for `backend`, `nginx`, and `frontend` — this is the one tier where the HPAs are actually exercised day to day, since kind is where load-testing a scale event is cheap to try.
- **CI-published prod images, pinned to a verified commit SHA** for `backend.image`/`frontend.image` — the chart's own default (`values.yaml`) points at `:local` tags for images you build yourself; this file switches the cluster to the already-verified images CI publishes instead. Each pin is a manual, static reference — it doesn't auto-update, so bump it by hand after a push you've actually checked.
- **Throwaway MySQL credentials** — the same values `compose.yml` uses, meant for local development only (see `docs/helm.md`'s Secrets section for the `existingSecret` mechanism a real environment uses instead).

## Deploying a change

The full sequence — classify the change, rebuild only what changed, load the image, check for an image pin before trusting a rebuilt `:local` tag, lint/template/diff before applying, then verify against the live cluster rather than trusting `helm upgrade`'s own success — is written out as a runbook in `.claude/skills/kind-deploy-verify/SKILL.md` rather than duplicated here. The one thing worth calling out directly: **if the component you just rebuilt is one of the two pinned above**, don't edit `values-local.yaml` to test a single change — that file encodes a deliberate decision (test against CI-verified images) that a one-off edit would quietly undo. Override it for just that `helm upgrade` instead:

```bash
helm upgrade csat kubernetes/chart -n csat -f kubernetes/chart/values-local.yaml \
  --set backend.image.repository=csat-php --set backend.image.tag=local \
  --wait --timeout 3m
```

## Verifying

```bash
kubectl -n csat get pods
curl -s -w '  HTTP %{http_code}\n' http://api.localtest.me/healthz
curl -s -w '  HTTP %{http_code}\n' http://api.localtest.me/api/static-pages
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://app.localtest.me/
```

A Pod reaching `Running`/`Ready` only proves it started and passed its probes — the same caution that applies on the dev tier (`docs/dev/kubernetes.md`'s final section) applies here too, just without any of the AWS-networking-specific failure modes, since kind never leaves your own machine.
