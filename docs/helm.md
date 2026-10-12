# Helm Chart

One chart (`kubernetes/chart`) deploys this app's four workloads — `mysql`, `php` (backend), `nginx`, `web-user` (frontend) — to every environment: the local kind cluster, the EC2 dev tier, and (eventually) staging. Only the values file changes per environment; the templates themselves are environment-agnostic. This doc covers the chart's own structure and conventions — environment-specific behavior lives in `docs/dev/kubernetes.md` for the dev tier.

## Values tiering

| File | Tier | Tracked in git? |
|---|---|---|
| `values.yaml` | defaults shared by every environment | yes |
| `values-local.yaml` | local kind cluster, overrides `values.yaml` | yes |
| `values-dev.yaml` | EC2 dev tier (`terraform/dev`) | yes |
| *(future)* `values-staging.yaml` | self-hosted/EKS staging tier | — |

`values.yaml:1-7` states the rule directly: resource **names** (`mysql`, `php`, `nginx`, `web-user`) are fixed on purpose, because `nginx`'s `default.conf` reaches `php` at the literal hostname `php:9000` and the app reaches the database at the literal hostname `mysql` — a per-release name prefix (Helm's usual `{{ .Release.Name }}-php` convention) would break both. The practical consequence: **install one release per namespace**, never multiple releases of this chart side by side in the same namespace.

A values file only needs to override what differs for that tier — `values-dev.yaml` is ~90 lines against `values.yaml`'s ~130 precisely because it only states the nip.io hostnames, the published image tags, and the MySQL memory bump, leaving everything else (resource shapes, probe timings, chart structure) inherited.

## Chart identity

`Chart.yaml` pins `apiVersion: v2` (Helm 3), `type: application`, and its own `version`/`appVersion` (currently both `0.1.0`) — these aren't yet tied to a release process; bump `version` when the chart's templates change in a way worth tracking, and `appVersion` to reflect whatever application version it deploys (though in practice the app's actual version is the image tag in each values file, not this field).

## Helpers

`templates/_helpers.tpl` currently defines one named template, `csat.dbSecretName` — it resolves to `.Values.mysql.existingSecret` if set, else the fixed name `csat-db` (`_helpers.tpl:1-4`). Every template that needs the DB credentials Secret (`secret.yaml`, `configmap.yaml`'s sibling usages, `mysql/statefulset.yaml`, `backend/deployment.yaml`, `backend/migrate-job.yaml`) calls `{{ include "csat.dbSecretName" . }}` rather than repeating that `default` logic — add new shared logic here rather than copy-pasting a snippet across multiple templates.

## Secrets: `existingSecret` vs. chart-created

`mysql.existingSecret` is the fork point between "local development" and "anything else" (`secret.yaml:1-12`, `values.yaml:21-29`):

- **Empty** (the default): the chart creates its own Secret (named via `csat.dbSecretName`, so `csat-db` unless overridden) from `mysql.credentials.password`/`rootPassword` in the values file — meant for local development only, since those plaintext values end up in the values file and in the Helm release's stored values.
- **Set**: the chart creates no Secret at all; whatever already exists under that name (e.g. synced from AWS Secrets Manager in a real environment) is used as-is. `required(...)` guards on `credentials.password`/`rootPassword` (`secret.yaml:10-11`) only fire in the first branch, so setting `existingSecret` is also how you avoid needing those two fields populated at all.

## Config: ConfigMap vs. Secret split

`configmap.yaml` carries every *non-secret* setting the `php` container reads as environment variables (`APP_ENV`, `DB_NAME`, `DB_USER`, `DB_HOST`, `CORS_ALLOW_ORIGIN`) — `DB_HOST` is hardcoded to the literal `mysql` service name, not a value, for the same single-release-per-namespace reason as above. `DB_PASS` alone comes from the Secret (`backend/deployment.yaml:49-54`), injected via `secretKeyRef` rather than `envFrom`, so it never appears in a `kubectl describe`/manifest dump of the ConfigMap.

`backend/deployment.yaml:25-28` hashes the ConfigMap's rendered content into a Pod template annotation (`checksum/config`) — environment variables are only read when a container starts, so without this, changing a ConfigMap value and running `helm upgrade` would silently leave old Pods running with stale config until something else happened to restart them. The checksum changes whenever the ConfigMap's content does, which changes the Pod template, which is what actually triggers the rollout.

## Rolling update strategy

`backend/deployment.yaml:9-17` and `nginx/deployment.yaml` both set `strategy.rollingUpdate` explicitly (`maxSurge: 1, maxUnavailable: 0`) rather than relying on the Deployment default of `25%/25%`. At a single replica those happen to round to the same effective behavior, which is exactly why leaving it implicit is a trap: it stops being zero-downtime the moment `replicas` (or the HPA) changes it to anything higher, since `25%` of a larger number stops rounding down to zero `maxUnavailable`. Being explicit means "always start the new Pod and wait for it to be Ready before removing the old one" holds regardless of replica count.

Both `php` and `nginx` also set a `preStop` hook (`sleep 5`) for the same underlying race: the process stops accepting connections almost immediately on `SIGTERM`, which can outrun kube-proxy/ingress-nginx actually removing the terminating Pod from the Service's endpoint list. This was verified against a live cluster, not assumed — without the delay, a rollout dropped 1/200 requests for `php` and 3/200 for `nginx`; with it, 0/200 for both.

## Probes: readiness vs. liveness, chosen per failure mode

- **`php`**: both probes are a plain TCP check on 9000 (`backend/deployment.yaml:55-64`) — php-fpm itself, not the app behind it.
- **`nginx`**: readiness is an HTTP `GET /healthz` (end to end: nginx → php-fpm → app), liveness is a TCP check on nginx itself (`nginx/deployment.yaml:63-73`). The split is deliberate: traffic should only reach a Pod that can really serve a request (readiness), but restarting nginx wouldn't fix a broken `php` behind it, so liveness doesn't try to use the same end-to-end check.
- **`mysql`**: a `startupProbe` (`mysqladmin ping`, up to 30 × 5s = 150s) gates both readiness and liveness until a slow first-time init finishes, specifically so a cold start can't get the container killed mid-init (`mysql/statefulset.yaml:54-66`). `mysqladmin ping` needs no credentials — it exits `0` even on "Access denied," and `1` only when the server isn't answering at all — which is why the Pod spec never needs to carry a password just to run these probes.

## Autoscaling: `replicas` vs. HPA, never both active

`backend.autoscaling.enabled` (and the matching `nginx`/`frontend` fields) defaults to `false`; each Deployment template only sets `spec.replicas` when autoscaling is disabled (`backend/deployment.yaml:6-8`) — when it's enabled, the HPA (`backend/hpa.yaml`) owns replica count instead. `values.yaml:59-62` spells out why both can't be live at once: leaving `.replicas` set while the HPA is also active would make every `helm upgrade` fight the HPA — Helm resets the count to the values-file number, the HPA changes it back, repeatedly, on every reconcile.

## PodDisruptionBudgets

Every workload's PDB uses `maxUnavailable: 1`, not `minAvailable: 1` — covered in detail in `docs/dev/kubernetes.md` since the reasoning (idling at 1 replica, `minAvailable` would block disruptions forever at rest) is the same for every tier, not dev-specific; not duplicated here.

## MySQL: StatefulSet, not Deployment

`mysql/statefulset.yaml:1-6` explains the choice directly: a StatefulSet gives the single MySQL Pod a stable identity (`mysql-0`) and guarantees the old Pod is never replaced while it might still be running, and its PVC (`data-mysql-0`, from `volumeClaimTemplates`) survives a `helm uninstall`/reinstall of the release. In kind, the default StorageClass still provisions that volume on the node itself, so `kind delete cluster` wipes it regardless — the StatefulSet protects against a *chart* lifecycle event, not a cluster teardown. A real environment replaces this whole template with Amazon RDS via `mysql.existingSecret` plus pointing `DB_HOST` elsewhere (not yet wired up as a values toggle — currently `configmap.yaml:12` hardcodes `DB_HOST: mysql`).

No CPU `limit` is set anywhere in the chart, only CPU `requests` plus a memory `limit` — `values.yaml:30-34`'s comment on `mysql.resources` states why: a CPU limit only throttles, it doesn't protect the node from memory pressure the way a memory limit does, and MySQL in particular is "the one thing that shouldn't get OOMKilled mid-write." The dev tier's OOMKill incident (`docs/dev/aws.md`) confirmed the memory side of that concern for real.

## Lint, template, diff — before every apply

`.claude/skills/kind-deploy-verify/SKILL.md` codifies the actual workflow, worth repeating here since it applies to any tier, not just kind:

```bash
helm lint kubernetes/chart -f kubernetes/chart/values-local.yaml
helm template csat kubernetes/chart -n csat -f kubernetes/chart/values-local.yaml \
  | kubectl diff -n csat -f -
```

`kubectl diff` against a freshly-rendered template catches mistakes `helm lint` can't — e.g. a duplicate YAML key that silently clobbers a value — by showing exactly what would change against the live cluster before anything is actually applied. The `migrate` Job (`backend/migrate-job.yaml`) always shows up in that diff as if newly created, which is expected noise: it's a Helm hook with `hook-delete-policy: before-hook-creation,hook-succeeded`, so it deletes itself after a successful run and never exists between deploys for `kubectl diff` to compare against.

## Ingress: one template, per-tier className/annotations

`templates/ingress.yaml` is shared across every tier; only `ingress.enabled`, `ingress.className`, and the two hostnames vary per values file (`values.yaml:122-129` disables it and defaults `className: nginx`; `values-dev.yaml` enables it with nip.io hostnames). The template's own comment (`ingress.yaml:5`) already flags what a managed-Kubernetes tier would need instead: real hostnames and an ALB-specific `className`/annotations rather than ingress-nginx — see `notes/aws-qna.md`'s EKS-vs-EC2 comparison for why that's more than a values change (the template currently has no annotations block to carry AWS Load Balancer Controller's required `alb.ingress.kubernetes.io/*` keys).
