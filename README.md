# ml-api Helm Platform

A generic, production-shaped Helm chart for deploying ML inference APIs, plus a small
real service (`ml-api`) that exercises every knob the chart exposes.

This is a take-home for **Money Forward India, MLOps Platform Engineering**. The
assignment is explicit that grading is on *approach, feasibility, and outside-the-box
thinking*, not on running production infrastructure.

## The idea

Most take-homes in this space produce a Deployment YAML and call it done. The scenario
here is deliberately platform-shaped instead: **a platform team owns one Helm chart**,
and **MLEs onboard their models to it by writing a handful of lines in a values file**,
never touching a template. The chart owns everything that's easy to get wrong and
expensive to get wrong differently across teams (probes, security context, resource
tiers, autoscaling, secrets wiring), and exposes only what a model actually differs on:
image, env vars, resource sizing.

The sample app (`app/`) is a real FastAPI service serving a tiny scikit-learn Iris
classifier, not a static "Hello World." The assignment explicitly allows the latter,
but a real model gives probes, model-version metadata, and the security posture
something genuine to be tested against.

## Repo layout

```
app/            FastAPI + sklearn sample ML API (the thing being deployed)
helm/ml-api/    The generic Helm chart, the actual deliverable
  templates/    Deployment, Service, HPA, Secret, ServiceAccount, helm-test hook
  tests/        helm-unittest specs (static, offline, run in CI on every PR)
  values.yaml   Platform defaults every environment inherits
  values-{dev,staging,prod}.yaml   Per-environment overrides, MLE-facing surface
iac/terraform/  Small Terraform snippet: same chart, invoked via `helm_release`
.github/workflows/helm-chart.yml   CI/CD: lint/test/validate, package, publish to ECR
.github/workflows/app-image.yml    CI/CD: build/smoke-test/publish the app image
```

## Prerequisites

Everything below runs entirely on a local machine, no cloud account needed.

**macOS** (Homebrew):

```bash
brew install docker minikube kubectl helm terraform
helm plugin install https://github.com/helm-unittest/helm-unittest.git   # not bundled with Helm
```

**Windows** (winget, in PowerShell):

```powershell
winget install Docker.DockerDesktop Kubernetes.minikube Kubernetes.kubectl Helm.Helm HashiCorp.Terraform
helm plugin install https://github.com/helm-unittest/helm-unittest.git
```

Restart the terminal after `winget install` so the new `PATH` entries take effect. The
`helm plugin install` step needs Git for Windows on `PATH` (`winget install Git.Git` if
it isn't already); Docker Desktop needs WSL 2 enabled and must be running before
`minikube start`. Everywhere else in this README, run the same commands from PowerShell
as-is; the only Windows-specific difference is this install step and using PowerShell's
line-continuation (`` ` ``) instead of `\` if a command is split across lines.

**Linux**: same package names are available via the distro's package manager (`apt`,
`dnf`, `pacman`, ...) or each tool's official install script; Docker Engine substitutes
for Docker Desktop.

Versions this was built and verified against: Docker 29, Minikube v1.39, kubectl
v1.37, Helm v4.1 (`helm-unittest` plugin v1.1.2), Terraform 1.5.7. A Docker daemon
(Docker Desktop, Colima, or Docker Engine) needs to be running before `minikube start`.

## Quickstart (Minikube)

```bash
minikube start

# Build the app image and load it straight into the node, no registry needed locally
docker build -t ml-api:v2 app/
minikube image load ml-api:v2

helm unittest helm/ml-api                                   # static chart tests
helm upgrade --install ml-api helm/ml-api -f helm/ml-api/values-dev.yaml
helm test ml-api                                             # live smoke test (see below)

kubectl port-forward svc/ml-api 8000:80
curl http://127.0.0.1:8000/health
curl -X POST http://127.0.0.1:8000/predict \
  -H "Content-Type: application/json" \
  -d '{"sepal_length":5.1,"sepal_width":3.5,"petal_length":1.4,"petal_width":0.2}'
```

## The chart

**One chart, three environments, no branching.** `values.yaml` is the full schema and
the platform-safe defaults (probes, security context, resource requests/limits,
ServiceAccount). Each `values-{dev,staging,prod}.yaml` overrides *only what differs*;
`values-staging.yaml` is a single line. Environments differ by config, never by template
logic, so there is no `{{ if .Values.environment == "prod" }}` anywhere in this chart.
That's what makes "MLE edits a minimal values file" true rather than aspirational.

**Security posture is opt-out, not opt-in.** Every release gets a non-root user, a
read-only root filesystem, all Linux capabilities dropped, and a dedicated
`ServiceAccount` with no mounted API token, by default, with no values file needing to
ask for it.

**HPA and `replicaCount` never fight.** The Deployment omits `replicas:` entirely when
`autoscaling.enabled` is true, so a `helm upgrade` can't undo what the HPA just did under
load.

**Secrets have exactly one production-safe path.** `existingSecret` references a Secret
created out-of-band by a real secrets system (External Secrets, Sealed Secrets, the AWS
Secrets Manager CSI driver, ...) and always wins when set. The chart can also manage a
Secret itself (`secrets.create: true`), but that path exists only for local demos and
must be populated with `--set` at install time, never committed to a values file.
Verified end-to-end on Minikube: a secret passed via
`--set secrets.data.API_KEY=...` reaches the container as an env var, and the plaintext
never touches a file in this repo.

**Two independent test layers**, because a chart can render perfect YAML and still
deploy an app that never answers a request, or the reverse:

- `helm unittest helm/ml-api`: 16 static assertions over template output, covering
  defaults, security context, HPA/Secret conditional rendering, the `required()`
  guardrails on `image.repository`/`image.tag`, and the real dev/staging/prod values
  files. Runs in CI on every PR that touches `helm/**`.
- `helm test ml-api`: a `helm.sh/hook: test` Pod that curls `/health` and `/predict`
  against a real, running release and checks it gets back an actual prediction.

## CI/CD

Two independent pipelines, because the app image and the chart version independently
(see Version-control strategy below) and shouldn't rebuild each other on every change:

**[.github/workflows/helm-chart.yml](.github/workflows/helm-chart.yml)**, the chart pipeline:

1. **`validate`** (every PR touching `helm/**`): `helm lint`, then `helm unittest`,
   then render `values-{dev,staging,prod}.yaml` with `helm template`, then validate
   every rendered manifest against the Kubernetes API schema with `kubeconform`.
2. **`publish`** (push to `main` only, gated on `validate` passing): reads the chart
   version out of `Chart.yaml`, authenticates to AWS via OIDC (no long-lived access keys
   stored as a repo secret), refuses to run if that version is already published, then
   `helm package`s and `helm push`es the chart to a **private ECR OCI repository**.

**[.github/workflows/app-image.yml](.github/workflows/app-image.yml)**, the app image pipeline:

1. **`build`** (every PR touching `app/**` or `Chart.yaml`): builds the Docker image and
   runs a container smoke test against a real running container (`/health`, then
   `/predict` with a real payload, checking the response actually contains a prediction).
2. **`publish`** (push to `main` only, gated on `build` passing): authenticates to AWS
   via OIDC, refuses to run if the image tag (read from `Chart.yaml`'s `appVersion`) is
   already published, then builds and pushes to the same private ECR account the chart
   uses.

The registry, account ID, and IAM role ARNs in both workflows are placeholders. There's
no real AWS account behind this take-home to publish to, and the assignment doesn't
expect one. Both workflows are written to be *correct*, not to actually execute against
real infrastructure. ECR was chosen over GHCR/Harbor/Artifact Registry
specifically so the app image and the chart share one registry story rather than two.

## IaC (Terraform)

[iac/terraform/](iac/terraform/) is a deliberately small snippet, clean through
`terraform init`/`validate`/`plan` against the same Minikube kubeconfig used everywhere
else in this README. A single `helm_release` resource installs the exact same chart
with the exact same `values-<environment>.yaml` overlay `helm upgrade --install` uses.
Terraform plugs in as *a caller of the chart*, not a reimplementation of it. It
intentionally does not provision a cluster, VPC, or IAM: that's out of scope for "chart
deployed to a cluster" and would need real cloud credentials this take-home doesn't have.

```bash
cd iac/terraform
terraform init
terraform plan -var="environment=dev"   # targets Minikube by default, zero cloud spend
```

Verified live against a running Minikube cluster (not just `validate`): `plan` resolves a
real `1 to add` diff against the actual dev values. `apply` was deliberately not run here,
to avoid installing a second, Terraform-managed release on top of the one the Quickstart
above already manages directly through `helm`; running it against an empty namespace
works the same way.

## Version-control strategy

- **Trunk-based, `main` protected.** All changes land via PR; the `validate` CI job
  (lint, unit tests, schema validation) is a required check before merge.
- **Chart version is the release boundary, not a branch.** `Chart.yaml`'s `version` is
  bumped semver-style (patch for template/values fixes, minor for new capabilities, major
  for breaking values-schema changes) in the same PR as the change. The `publish` job
  hard-fails a merge to `main` if that version is already in the registry, so the version
  bump is enforced, not a convention people forget.
- **`appVersion` tracks the app, `version` tracks the chart, and they move
  independently.** A chart-only change (e.g. adding a new probe knob) bumps `version`
  without touching `appVersion`; a new model image bumps `appVersion` (and typically
  just `values-<env>.yaml`'s `image.tag`) without necessarily touching the chart at all.
- **Environments are promoted through values files, not branches.** There is no
  `dev`/`staging`/`prod` branch per environment. One chart version is promoted from dev
  to staging to prod by pointing each environment's `helm upgrade` at that same
  immutable, already-published chart version with its own values file. This avoids the
  classic "which branch is actually in prod" drift that per-environment branching
  produces.
- **No secrets in git, ever**, enforced structurally rather than by policy. See Secrets
  above.

## Outside-the-box / novel ideas

Implemented now:

- **Model/app metadata surfaced through the platform itself.** `MODEL_VERSION` is
  injected from `image.tag` (not hand-maintained), and `app.kubernetes.io/version`
  carries the same value as a label, so `kubectl get pods -L app.kubernetes.io/version`
  answers "which model version is actually running" without hitting the API.
- **A standardized health contract every onboarded ML API must satisfy.** `probes.*`
  in `values.yaml` plus a documented `/health` convention means the platform team
  defines what "ready" means once, instead of every model team reinventing probes.
- **Cost-aware environment defaults.** Dev requests 50m CPU / 64Mi memory; prod requests
  250m / 256Mi and turns on HPA (3-10 replicas). The chart's defaults nudge toward not
  overpaying for dev/staging capacity nobody needs, without an MLE having to know to ask.

Sketched as future evolution rather than built (time-boxed for a take-home, called out
honestly rather than implied as done):

- **Progressive delivery / canary.** The chart's `service` + `Deployment` selector
  already isolate one release's Pods cleanly. The natural next step is a second,
  weighted Service (or a mesh's traffic-split CRD) fed by the *same* values-file
  pattern, e.g. `canary.weight: 10`, so a canary rollout is still "edit a values file,"
  not a new workflow to learn.
- **GitOps (ArgoCD) integration path.** This chart already assumes nothing about *how*
  `helm upgrade` gets invoked, so handing it to an ArgoCD `Application` pointed at the
  published OCI chart plus a values file per environment is a drop-in swap for the CI
  `publish` job triggering deploys directly. No chart or values changes required, only
  who calls `helm`.

## Known gaps (stated honestly, not hidden)

These are the places a real production setup would diverge from this take-home, called
out explicitly rather than glossed over:

- Model training happens inside the Docker build. A real pipeline trains once, versions
  the artifact independently (MLflow/W&B plus a registry), and the serving image only
  ever pulls a specific artifact version.
- Liveness and readiness share one endpoint, safe only because this model loads
  synchronously at import time. A model with slow/lazy loading needs genuinely separate
  signals.
- No scratch space (`emptyDir`) is exposed as a value despite `readOnlyRootFilesystem:
  true`. This app needs none; a real model needing runtime caching would need that
  added.
- The CI/CD workflows and Terraform snippet reference a placeholder AWS account/registry
  and neither has been run against real cloud infrastructure, by design.
