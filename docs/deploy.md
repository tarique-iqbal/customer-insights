# Deploying a Change (Local, Dev, and Staging)

All three tiers run the same Helm chart (`docs/helm.md`) against CI-published images rather than against whatever happens to be on your machine — `values-local.yaml`, `values-dev.yaml`, and `values-staging.yaml` each pin `backend.image.tag`, `nginx.image.tag`, and `frontend.image.tag` to a specific commit SHA, not `latest`. This doc covers the workflow that gets a merged change from source into those pins and onto each live cluster — the chart/cluster mechanics themselves live in `docs/helm.md`, `docs/local/kind.md`, `docs/dev/*.md`, and `docs/staging/*.md`.

## Why a SHA pin, not `latest`

`.github/workflows/ci-client.yml`'s `publish` job (and `ci-api.yml`'s, for `csat-php`/`csat-nginx`) pushes every image under two tags: the commit SHA and `latest`. The values files pin the SHA, never `latest`, for the same reason `docs/local/kind.md` already states for the frontend: a floating tag would mean the cluster's actual behavior depends on whenever you happen to redeploy, not on a commit you deliberately checked. The pin is a manual, static reference — it does not update itself, so nothing here happens automatically on a push.

All three component images (`backend`, `nginx`, `frontend`) are pinned this way in every tier's values file — none of them fall back to `values.yaml`'s own `:local` defaults. Bumping only the component(s) that actually changed is fine; the others simply keep their current SHA.

## Step 1: push and let CI publish

```
git push
```

Pushing to `main` triggers whichever of `ci-api.yml`/`ci-client.yml` matches the changed paths. Each runs its own gate — `quality` → `test(s)` → `build` → `publish` — and `publish` only runs if every job before it passed and the branch is `main`. Wait for that run to go green (`gh run list`/`gh run watch`) before moving on — the SHA you're about to pin doesn't have an image behind it until `publish` finishes.

The commit SHA you just pushed (`git rev-parse HEAD`) is the tag both `ghcr.io/.../csat-php` (or `csat-web-user`) now carry.

## Step 2: bump the pin in all three values files

Edit `backend.image.tag`, `nginx.image.tag`, and/or `frontend.image.tag` — whichever component(s) you changed — in **all three**:

- `kubernetes/chart/values-local.yaml`
- `kubernetes/chart/values-dev.yaml`
- `kubernetes/chart/values-staging.yaml`

to the new SHA. These three files are edited together deliberately: there's one chart and one set of CI-published images behind it, so a pin bump is a statement about which commit is "the current verified build," not a per-tier decision. Commit that change.

## Step 3.a: redeploy — local (kind)

The cluster is already running, so this is just a chart upgrade:

```bash
helm upgrade csat kubernetes/chart -n csat -f kubernetes/chart/values-local.yaml --wait --timeout 3m
```

No `--set` override needed here — that flag is only for testing a locally-built `:local` image against a pinned component without touching the file (`docs/local/kind.md`'s "Deploying a change" section). Since the file itself now carries the new SHA, a plain `-f values-local.yaml` upgrade is sufficient. **This also means a `--set` override from an earlier one-off test never lingers**: it only ever applied to the single `helm upgrade` call it was passed on, not to the file, so the very next upgrade that omits it reverts the release to whatever the values file says — Helm's three-way merge diffs against its own previously-stored release manifest, which already differs from the `--set` value you're leaving out, and replaces it correctly.

(`kubectl diff` on a Service whose `port`/`targetPort` number itself just changed can show a spurious *second*, unnamed port and fail with `spec.ports[0].name: Required value` — that's `kubectl diff` falling back to a plain two-way merge because Helm-managed resources carry no `kubectl.kubernetes.io/last-applied-configuration` annotation for it to three-way-merge against. `helm upgrade --dry-run` renders the real, single-port result; trust that over `kubectl diff` for this specific shape of change.)

Then verify per `docs/local/kind.md`'s Verifying section (Pod readiness, the three curl checks).

## Step 3.b: redeploy — dev (EC2)

The dev tier has no standing cluster by design (`docs/dev/terraform.md`) — a pin bump here doesn't deploy anything by itself. It takes effect the next time `./run.sh` runs end to end: `run.sh:133-134` renders `values-dev.yaml` into a temp file (substituting the real worker IP for every `REPLACE_ME_WORKER_IP`) immediately before `helm upgrade --install`, so whatever SHA is sitting in the committed `values-dev.yaml` at that moment is what gets deployed. If the dev environment happens to already be up when you bump the pin, re-run just the Helm step yourself against that same rendered file rather than re-running all of `run.sh`; if it's destroyed (the normal state between sessions), the next `./run.sh` picks up the new pin automatically — nothing extra to do.

## Step 3.c: redeploy — staging (EKS)

Unlike dev, staging's cluster is meant to stay up between sessions (`docs/staging/terraform.md`) — so a pin bump here behaves like kind's Step 3.a, not like dev's `run.sh`-driven Step 3.b. No `REPLACE_ME`-style substitution either, since `values-staging.yaml` uses placeholder hostnames that don't need to resolve, not an IP known only after `terraform apply`. Apply it directly against the already-running cluster:

```bash
helm upgrade csat kubernetes/chart --namespace csat -f kubernetes/chart/values-staging.yaml --wait --timeout 8m
```

Then verify per `docs/staging/debugging.md`'s approach: curl the ALB's real hostname with an explicit `Host:` header (`kubectl get ingress csat -n csat` to find it), not the placeholder hostnames themselves — those were never meant to resolve. Watch for the ALB target-group warmup race documented there if this redeploy happens to create a brand-new ALB rather than reusing an existing one.

## Summary

| Step | Local (kind) | Dev (EC2) | Staging (EKS) |
|---|---|---|---|
| 1. Push, CI publishes | same for all three — one push, every tier reads from the same `ghcr.io` images | | |
| 2. Bump pin | same commit, all three values files | | |
| 3. Apply | `helm upgrade` against the already-running cluster | next `./run.sh`, or a manual `helm upgrade` if the environment happens to be up | `helm upgrade` against the already-running cluster, same shape as kind |
| 4. Verify | `docs/local/kind.md` Verifying section | `docs/dev/kubernetes.md`'s final section | `docs/staging/debugging.md`'s verification approach (`Host:` header against the ALB) |
