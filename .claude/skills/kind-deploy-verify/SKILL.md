---
name: kind-deploy-verify
description: Deploy a code or chart change to this repo's local kind cluster (release "csat", namespace "csat") and verify it actually works against the live cluster, not just that helm reported success. Use this whenever the user asks to deploy, redeploy, push a change to kind, update the cluster, reload an image, apply the chart, or verify something works in kind/kubernetes for this project — including phrases like "try this in kind", "update the cluster with my change", "load the new image", or after editing files under api-service/, web-user/, docker/, or kubernetes/chart/ and the user wants to see it running live.
---

# Deploy to kind and verify

This encodes a sequence that has gone wrong twice before in exactly the ways described below — follow it in order rather than reconstructing it from memory, since both failure modes are silent (no error, just the wrong thing running).

## Step 0: figure out what actually changed

Check `git status`/recent edits to classify the change:

- **App code or a Dockerfile** (`api-service/`, `web-user/src`, `docker/php/Dockerfile`, `docker/nginx/`, `docker/web-user/Dockerfile`) → needs a rebuilt image. Go to Step 1.
- **Chart-only** (`kubernetes/chart/**`, e.g. a values tweak or a new resource, nothing in the images changed) → no image rebuild needed. Skip straight to Step 3.

Only rebuild the component(s) that actually changed — rebuilding and reloading all three every time wastes time and risks disturbing a pin you didn't mean to touch (see Step 2).

## Step 1: rebuild and load the changed image(s)

| Component | Build command (from repo root) | kind load | Deployment name |
|---|---|---|---|
| php (backend) | `docker build -t csat-php:local -f docker/php/Dockerfile .` | `kind load docker-image csat-php:local --name csat` | `php` |
| nginx | `docker build -t csat-nginx:local docker/nginx` | `kind load docker-image csat-nginx:local --name csat` | `nginx` |
| web-user (frontend) | `docker build -t csat-web-user:local -f docker/web-user/Dockerfile .` | `kind load docker-image csat-web-user:local --name csat` | `web-user` |

For php and web-user, an untargeted build (no `--target`) produces the `dev` stage by design — that's the one with xdebug/test tooling or the Vite dev server, matching what every other build command in this repo expects. Only pass `--target prod` if you specifically mean to test the production image (check with the user first — that image behaves differently, e.g. web-user serves a static build on port 80, not the dev server on 5173).

After loading, restart the Deployment and wait for it to actually be ready **before touching Helm**:

```bash
kubectl -n csat rollout restart deploy/<name>
kubectl -n csat rollout status deploy/<name> --timeout=90s
```

Why this has to happen before `helm upgrade`, not after or at the same time: if a chart change depends on something new in the image (e.g. a new `/healthz` route that a readiness probe now checks), and you run `helm upgrade` first, the *new* Pod template's readiness probe fails against the *old* image still running, the Pod never goes Ready, and Helm's `--wait` times out — this happened for real once. Doing it in this order means by the time Helm runs, the image already behaves correctly.

## Step 2: check whether this component is pinned to a published image

Before assuming your rebuilt `:local` image will actually run, check `kubernetes/chart/values-dev.yaml`:

```bash
grep -A2 "^backend:\|^frontend:\|^nginx:" kubernetes/chart/values-dev.yaml
```

As of this writing, `backend.image` and `frontend.image` are pinned to specific `ghcr.io/.../csat-{php,web-user}:<sha>` tags (from switching the cluster to the real CI-published images) — `nginx.image` isn't overridden there, so it still defaults to `values.yaml`'s `csat-nginx:local`. **Check the current file rather than trusting this**, since pins get added or removed over time.

If the component you rebuilt is pinned: don't edit `values-dev.yaml` to test one change (that's a separate decision about switching the cluster back to local dev images generally, not implied by wanting to verify this one edit). Instead, override it just for this deploy:

```bash
helm upgrade csat kubernetes/chart -n csat -f kubernetes/chart/values-dev.yaml \
  --set backend.image.repository=csat-php --set backend.image.tag=local \
  --wait --timeout 3m
```

(substitute `backend`/`frontend` as appropriate — `nginx` needs no override since it isn't pinned).

## Step 3: lint, preview, then apply

Always preview before applying — this has caught real mistakes before (a duplicate YAML key that silently clobbered a value, confirming a diff only touched what was intended).

```bash
helm lint kubernetes/chart -f kubernetes/chart/values-dev.yaml
helm template csat kubernetes/chart -n csat -f kubernetes/chart/values-dev.yaml \
  | kubectl diff -n csat -f -
```

The diff will always show a `migrate` Job as if newly created — that's expected noise, not a problem: it's a Helm hook that deletes itself after a successful run (`hook-delete-policy: before-hook-creation,hook-succeeded`), so it never exists between deploys for `kubectl diff` to compare against. Everything else in the diff should match what you expect from the change you made; if something unexpected shows up, stop and figure out why before applying.

Then apply (add any `--set` overrides from Step 2 if needed):

```bash
helm upgrade csat kubernetes/chart -n csat -f kubernetes/chart/values-dev.yaml --wait --timeout 3m
```

## Step 4: verify for real

"Helm reported success" and "the rollout finished" both mean the Pod started, not that it's correct. Confirm it actually works:

```bash
kubectl -n csat get pods          # all Ready, restart counts not climbing
curl -s -w '  HTTP %{http_code}\n' http://api.localtest.me/healthz
curl -s -w '  HTTP %{http_code}\n' http://api.localtest.me/api/static-pages
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://app.localtest.me/   # if web-user changed
```

If the change touches the database, also confirm the data is what you expect (e.g. `kubectl -n csat exec mysql-0 -- mysql -uroot -psecret csat -N -e "SELECT COUNT(*) FROM migration_versions;"`), since a cluster recreation or a schema-affecting change can silently leave it empty or stale.

If what you're actually trying to prove is deeper than "it responds" — zero-downtime during a rollout, autoscaling under load, a disruption budget actually blocking an unsafe eviction — a single curl isn't enough evidence. `notes/k8s-roadmap.md` documents the heavier verification patterns used for exactly those (a curl loop running through a live `kubectl rollout restart`, generating real concurrent load to force an HPA scale event, calling the Kubernetes Eviction API directly) — read the relevant step there rather than re-deriving it.
