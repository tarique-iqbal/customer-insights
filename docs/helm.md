# Helm Chart

One chart (`kubernetes/chart`) deploys this app's four workloads — `mysql`, `php` (backend), `nginx`, `web-user` (frontend) — to every environment: the local kind cluster, the EC2 dev tier, and the EKS staging tier. Only the values file changes per environment; the templates themselves are environment-agnostic. This doc covers the chart's own structure and conventions — environment-specific behavior lives in `docs/local/kind.md`, `docs/dev/kubernetes.md` and `docs/staging/kubernetes.md`.

## Values tiering

| File | Tier | Tracked in git? |
|---|---|---|
| `values.yaml` | defaults shared by every environment | yes |
| `values-local.yaml` | local kind cluster, overrides `values.yaml` | yes |
| `values-dev.yaml` | EC2 dev tier (`terraform/dev`) | yes |
| `values-staging.yaml` | EKS staging tier (`terraform/staging`) | yes |

`values.yaml:1-7` states the rule directly: resource **names** (`mysql`, `php`, `nginx`, `web-user`) are fixed on purpose, because `nginx`'s `default.conf` reaches `php` at the literal hostname `php:9000` and the app reaches the database at the literal hostname `mysql` — a per-release name prefix (Helm's usual `{{ .Release.Name }}-php` convention) would break both. The practical consequence: **install one release per namespace**, never multiple releases of this chart side by side in the same namespace.

A values file only needs to override what differs for that tier — `values-dev.yaml` is ~80 lines against `values.yaml`'s ~130 precisely because it only states the nip.io hostnames, the published image tags, and the MySQL memory bump, leaving everything else (resource shapes, probe timings, chart structure) inherited.

## Chart identity

`Chart.yaml` pins `apiVersion: v2` (Helm 3), `type: application`, and its own `version`/`appVersion` (currently both `0.1.0`) — these aren't yet tied to a release process; bump `version` when the chart's templates change in a way worth tracking, and `appVersion` to reflect whatever application version it deploys (though in practice the app's actual version is the image tag in each values file, not this field).

## Helpers

`templates/_helpers.tpl` currently defines one named template, `csat.dbSecretName` — it resolves to `.Values.mysql.existingSecret` if set, else the fixed name `csat-db` (`_helpers.tpl:1-4`). Every template that needs the DB credentials Secret (`secret.yaml`, `mysql/statefulset.yaml`, `backend/deployment.yaml`, `backend/migrate-job.yaml`) calls `{{ include "csat.dbSecretName" . }}` rather than repeating that `default` logic — add new shared logic here rather than copy-pasting a snippet across multiple templates.

## Secrets: `existingSecret` vs. chart-created

`mysql.existingSecret` is the fork point between "local development" and "anything else" (`secret.yaml:1-12`, `values.yaml:21-29`):

- **Empty** (the default): the chart creates its own Secret (named via `csat.dbSecretName`, so `csat-db` unless overridden) from `mysql.credentials.password`/`rootPassword` in the values file — meant for local development only, since those plaintext values end up in the values file and in the Helm release's stored values.
- **Set**: the chart creates no Secret at all; whatever already exists under that name (e.g. synced from AWS Secrets Manager in a real environment) is used as-is. `required(...)` guards on `credentials.password`/`rootPassword` (`secret.yaml:10-11`) only fire in the first branch, so setting `existingSecret` is also how you avoid needing those two fields populated at all.

## Config: ConfigMap vs. Secret split

`configmap.yaml` carries every *non-secret* setting the `php` container reads as environment variables (`APP_ENV`, `DB_NAME`, `DB_USER`, `DB_HOST`, `CORS_ALLOW_ORIGIN`) — `DB_HOST` is hardcoded to the literal `mysql` service name, not a value, for the same single-release-per-namespace reason as above. `DB_PASS` alone comes from the Secret (`backend/deployment.yaml:51-56`), injected via `secretKeyRef` rather than `envFrom`, so it never appears in a `kubectl describe`/manifest dump of the ConfigMap.

`backend/deployment.yaml:25-28` hashes the ConfigMap's rendered content into a Pod template annotation (`checksum/config`) — environment variables are only read when a container starts, so without this, changing a ConfigMap value and running `helm upgrade` would silently leave old Pods running with stale config until something else happened to restart them. The checksum changes whenever the ConfigMap's content does, which changes the Pod template, which is what actually triggers the rollout.

## No ServiceAccount token in the app pods

All five pod templates (`php`, `nginx`, `web-user`, `mysql` and the `migrate` Job) set `automountServiceAccountToken: false`. The chart defines no ServiceAccount, so without this every pod would get the namespace's `default` ServiceAccount token mounted at `/var/run/secrets/kubernetes.io/serviceaccount/token`. None of these containers calls the Kubernetes API, so the token is only something an attacker could read and reuse after compromising a container. The `default` ServiceAccount has no RBAC permissions today, but any future binding to it would otherwise reach every app pod silently.

This doesn't affect probes, Services, HPAs, PDBs or NetworkPolicies, which the kubelet and control plane handle without a token inside the pod, or the add-ons in `kube-system` (ingress-nginx, the ALB Controller, EBS CSI), which use their own ServiceAccounts. A pod that later needs the Kubernetes API should get its own ServiceAccount with only the RBAC it needs, and set `automountServiceAccountToken: true`.

## Rolling update strategy

`backend/deployment.yaml:9-17`, `nginx/deployment.yaml` and `frontend/deployment.yaml` all set `strategy.rollingUpdate` explicitly (`maxSurge: 1, maxUnavailable: 0`) rather than relying on the Deployment default of `25%/25%`. At a single replica those happen to round to the same effective behavior, which is exactly why leaving it implicit is a trap: it stops being zero-downtime the moment `replicas` (or the HPA) changes it to anything higher, since `25%` of a larger number stops rounding down to zero `maxUnavailable`. Being explicit means "always start the new Pod and wait for it to be Ready before removing the old one" holds regardless of replica count.

`php`, `nginx` and `web-user` also set a `preStop` hook (`sleep 5`) for the same underlying race: the process stops accepting connections almost immediately on `SIGTERM`, which can outrun kube-proxy/ingress-nginx actually removing the terminating Pod from the Service's endpoint list. This was verified against a live cluster, not assumed — without the delay, a rollout dropped 1/200 requests for `php` and 3/200 each for `nginx` and `web-user`; with it, 0/200 for all three.

## Probes: readiness vs. liveness, chosen per failure mode

- **`php`**: both probes are a plain TCP check on 9000 (`backend/deployment.yaml:57-66`) — php-fpm itself, not the app behind it.
- **`nginx`**: readiness is an HTTP `GET /healthz` (end to end: nginx → php-fpm → app), liveness is a TCP check on nginx itself (`nginx/deployment.yaml:65-75`). The split is deliberate: traffic should only reach a Pod that can really serve a request (readiness), but restarting nginx wouldn't fix a broken `php` behind it, so liveness doesn't try to use the same end-to-end check.
- **`mysql`**: a `startupProbe` (`mysqladmin ping`, up to 30 × 5s = 150s) gates both readiness and liveness until a slow first-time init finishes, specifically so a cold start can't get the container killed mid-init (`mysql/statefulset.yaml:56-68`). `mysqladmin ping` needs no credentials — it exits `0` even on "Access denied," and `1` only when the server isn't answering at all — which is why the Pod spec never needs to carry a password just to run these probes.

## Autoscaling: `replicas` vs. HPA, never both active

`backend.autoscaling.enabled` (and the matching `nginx`/`frontend` fields) defaults to `false`; each Deployment template only sets `spec.replicas` when autoscaling is disabled (`backend/deployment.yaml:6-8`) — when it's enabled, the HPA (`backend/hpa.yaml`) owns replica count instead. `values.yaml:59-62` spells out why both can't be live at once: leaving `.replicas` set while the HPA is also active would make every `helm upgrade` fight the HPA — Helm resets the count to the values-file number, the HPA changes it back, repeatedly, on every reconcile.

## PodDisruptionBudgets

`php`, `nginx` and `web-user` each have a PDB using `maxUnavailable: 1`, not `minAvailable: 1` (mysql has none) — covered in detail in `docs/dev/kubernetes.md` since the reasoning (idling at 1 replica, `minAvailable` would block disruptions forever at rest) is the same for every tier, not dev-specific; not duplicated here.

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

`templates/ingress.yaml` is shared across every tier; only `ingress.enabled`, `ingress.className`, the two hostnames, and an optional `ingress.annotations` map vary per values file (`values.yaml:122-133` disables it and defaults `className: nginx` with no annotations; `values-local.yaml` enables it with `*.localtest.me` hostnames; `values-dev.yaml` enables it with nip.io hostnames; `values-staging.yaml` sets `className: alb` plus the AWS Load Balancer Controller's required `alb.ingress.kubernetes.io/{scheme,target-type}` keys via that annotations map).

The `{{- with .Values.ingress.annotations }}` block (`ingress.yaml:11-14`) carries the ALB Controller's keys and renders nothing when the map is empty. ingress-nginx (kind/dev) needs no annotations, so `local` and `dev` render no `annotations:` key at all.

## NetworkPolicy: least-privilege segmentation between workloads, where it's actually enforced

Each workload gets its own `NetworkPolicy` (`backend/`, `nginx/`, `frontend/`, `mysql/`), rather than one shared policy, so each one reads as a standalone answer to "who can this talk to, in each direction" — matching the chart's existing per-workload folder layout. Once a Pod is selected by *any* `NetworkPolicy` for a given direction (ingress or egress), Kubernetes makes that direction default-deny for that Pod — only what's explicitly listed is allowed, everything else silently drops. That's why there's no separate catch-all "deny everything" policy: each workload's own policy already is the deny-by-default boundary for exactly the traffic it covers.

The rules, and the reasoning behind each:

- **`mysql`**: ingress only from `app: php` and `app: migrate` (the migrate Job's Pod — see below) on `3306`; egress denied entirely. mysql never initiates a connection of its own, so there's nothing legitimate to allow outbound, and denying it anyway is a deliberate defense-in-depth move — if the container were ever compromised, it can't be used to reach anything else.
- **`php`**: ingress only from `app: nginx` on `9000` (nginx's `fastcgi_pass php:9000` is the only real caller); egress only to `app: mysql` on `3306`, plus DNS (UDP/TCP `53`) to `kube-system` so it can resolve the `mysql` hostname in the first place.
- **`nginx`**: egress only to `app: php` on `9000`, plus the same DNS allowance (it resolves `php` once at config-load — see `docs/dev/kubernetes.md`'s DNS-wait case). **Ingress is deliberately left unrestricted** — nginx is the public entry point on every tier, but *how* traffic arrives differs per tier (through an `ingress-nginx` controller Pod in kind/dev, or directly from an ALB's `target-type: ip` in staging, which has no controller Pod in-cluster at all to scope a `namespaceSelector` to). Picking one tier's shape would silently break another, so this policy only locks down the side that's actually the same everywhere: egress.
- **`web-user`**: egress denied entirely, same reasoning as nginx's ingress choice applied to the opposite side — it serves a static build (or the Vite dev server) with no server-side calls of its own, so there's nothing to allow. Ingress is unrestricted for the same cross-tier reason as nginx.

The DNS-egress rules target `kube-system` via `namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}` rather than a hand-maintained label — every namespace has gotten that label automatically since Kubernetes v1.21, specifically so policies like this don't depend on anyone remembering to label `kube-system` by hand.

**This is only as strong as the cluster's CNI.** A `NetworkPolicy` object is inert — accepted by the API server, visible in `kubectl get networkpolicy`, enforcing nothing — unless something actually implements it:

| Tier | CNI | Enforces `NetworkPolicy`? |
|---|---|---|
| kind | kindnet (a flannel fork) | No, by default — would need Calico or similar installed separately |
| dev (`terraform/dev`) | Flannel + k3s's bundled kube-router-based policy controller | **Yes**, on by default |
| staging (EKS) | Amazon VPC CNI | No — needs the managed `vpc-cni` EKS add-on with `enableNetworkPolicy: "true"`, which also runs the network policy agent (or Calico installed instead); not yet done in `terraform/staging` |

So right now, these policies are genuinely live only on the dev tier — on kind and staging they're correctly rendered and applied, but not yet backed by anything that reads them. That's still worth having: the policies document and are ready to enforce intent regardless, and nothing above needs to change when either gap closes — only the cluster's CNI configuration does.
