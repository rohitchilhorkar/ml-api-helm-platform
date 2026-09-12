# ml-api Helm Platform

A generic Helm chart for deploying ML inference APIs, plus a small real service
(`ml-api`) that uses every option the chart has.

This is a take-home for **Money Forward India, MLOps Platform Engineering**. The
assignment says clearly that grading is on *approach, feasibility, and outside the box
thinking*. It is not about running production infrastructure.

## The idea

The setup here is platform style on purpose. **A platform team owns one Helm chart.**
**MLEs onboard their models to it by writing a few lines in a values file.** They never
touch a template. The chart owns everything that is easy to get wrong: probes, security
context, resource tiers, autoscaling, secrets. It only exposes what a model actually
differs on: image, env vars, resource sizing.

The sample app (`app/`) is a real FastAPI service. It serves a tiny scikit-learn Iris
classifier, not a static "Hello World". The assignment allows a plain "Hello World"
image, but a real model gives the probes, the model version metadata, and the security
posture something real to test against.

## Repo layout

```
app/            FastAPI + sklearn sample ML API (the thing being deployed)
helm/ml-api/    The generic Helm chart, the actual deliverable
  templates/    Deployment, Service, HPA, PDB, Secret, ServiceAccount, helm test hook
  tests/        helm-unittest specs (static, offline, run in CI on every PR)
  values.yaml   Platform defaults every environment inherits
  values-{dev,staging,prod}.yaml   Per-environment overrides, the MLE-facing part
iac/terraform/aws-eks/  Terraform: builds a real EKS cluster, deploys the chart onto it
.github/workflows/helm-chart.yml   CI/CD: lint, test, validate, package, publish to ECR
.github/workflows/app-image.yml    CI/CD: build, smoke test, publish the app image
```

## Prerequisites

Everything below runs on a local machine. No cloud account is needed.

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
`helm plugin install` step needs Git for Windows on `PATH` (run `winget install Git.Git`
if it is not there yet). Docker Desktop needs WSL 2 enabled and running before
`minikube start`. Every other command in this README works the same in PowerShell. The
only real difference is this install step, and PowerShell uses `` ` `` for line
continuation instead of `\`.

**Linux**: the same tools are available through the distro package manager (`apt`,
`dnf`, `pacman`, or similar) or each tool's own install script. Docker Engine takes the
place of Docker Desktop.

Versions this was built and tested against: Docker 29, Minikube v1.39, kubectl v1.37,
Helm v4.1 (`helm-unittest` plugin v1.1.2), Terraform 1.5.7. A Docker daemon (Docker
Desktop, Colima, or Docker Engine) needs to be running before `minikube start`.

## Quickstart (Minikube)

```bash
minikube start

# Build the app image and load it straight into the node. No registry needed locally.
docker build -t ml-api:v2 app/
minikube image load ml-api:v2

helm unittest helm/ml-api                                   # static chart tests
helm upgrade --install ml-api helm/ml-api -f helm/ml-api/values-dev.yaml
helm test ml-api                                             # live smoke test, see below

kubectl port-forward svc/ml-api 8000:80
curl http://127.0.0.1:8000/health
curl -X POST http://127.0.0.1:8000/predict \
  -H "Content-Type: application/json" \
  -d '{"sepal_length":5.1,"sepal_width":3.5,"petal_length":1.4,"petal_width":0.2}'
```

## The chart

**One chart, three environments, no branching.** `values.yaml` holds the full schema
and the safe platform defaults: probes, security context, resource requests and limits,
ServiceAccount. Each `values-{dev,staging,prod}.yaml` only overrides what is different.
`values-staging.yaml` is a single line. Environments differ only by config, never by
template logic. There is no `{{ if .Values.environment == "prod" }}` anywhere in this
chart. That is what makes "MLE edits a minimal values file" actually true.

**Security is on by default, not something you turn on.** Every release gets a non-root
user, a read-only root filesystem, all Linux capabilities dropped, and its own
`ServiceAccount` with no mounted API token. No values file has to ask for this.

**HPA and `replicaCount` never fight each other.** The Deployment leaves out
`replicas:` completely when `autoscaling.enabled` is true. This means a `helm upgrade`
cannot undo what the HPA just did under load.

**A PodDisruptionBudget protects prod, and is off everywhere else.**
`podDisruptionBudget.enabled` is `false` by default. With `replicaCount: 1` in
dev and staging, `minAvailable: 1` would block the only pod from ever being evicted.
That would stop a node drain or a cluster upgrade from finishing. `values-prod.yaml`
turns it on with `minAvailable: 2` against a range of 3 to 10 replicas. This leaves
exactly one replica free to be disrupted at a time.

**Secrets have exactly one path meant for production.** `existingSecret` points at a
Secret created outside Helm, by a real secrets system such as External Secrets, Sealed
Secrets, or the AWS Secrets Manager CSI driver. It always wins when it is set. The chart
can also manage a Secret itself (`secrets.create: true`), but that path is only for
local demos. It must only be filled in with `--set` at install time, never committed to
a values file. This was checked end to end on Minikube: a secret passed with
`--set secrets.data.API_KEY=...` reaches the container as an env var. The plain text
value never touches a file in this repo.

**Two test layers, checked separately.** A chart can render perfect YAML and still run
an app that never answers a request. It can also do the reverse.

- `helm unittest helm/ml-api`: 18 static checks on the rendered templates. This covers
  defaults, security context, HPA and PDB and Secret conditional rendering, the
  `required()` guards on `image.repository` and `image.tag`, and the real dev, staging,
  and prod values files. Runs in CI on every PR that touches `helm/**`.
- `helm test ml-api`: a `helm.sh/hook: test` Pod that calls `/health` and `/predict` on
  a real, running release, and checks it gets back an actual prediction.

## CI/CD

Two pipelines, kept separate because the app image and the chart version on their own
schedules (see Version control strategy below), and should not rebuild each other on
every change:

**[.github/workflows/helm-chart.yml](.github/workflows/helm-chart.yml)**, the chart pipeline:

1. **`validate`** (every PR touching `helm/**`): runs `helm lint`, then `helm unittest`,
   then renders `values-{dev,staging,prod}.yaml` with `helm template`, then checks every
   rendered manifest against the Kubernetes API schema with `kubeconform`.
2. **`publish`** (only on push to `main`, only after `validate` passes): reads the chart
   version from `Chart.yaml`, logs in to AWS through OIDC (no long-lived access keys
   stored as a repo secret), stops if that version is already published, then packages
   the chart and pushes it to a **private ECR OCI repository**.

**[.github/workflows/app-image.yml](.github/workflows/app-image.yml)**, the app image pipeline:

1. **`build`** (every PR touching `app/**` or `Chart.yaml`): builds the Docker image,
   scans it for known vulnerabilities, then runs a smoke test against a real running
   container: calls `/health`, then `/predict` with a real payload, and checks the
   response actually holds a prediction.
2. **`publish`** (only on push to `main`, only after `build` passes): logs in to AWS
   through OIDC, stops if the image tag (read from `Chart.yaml`'s `appVersion`) is
   already published, then builds and pushes to the same private ECR account the chart
   uses.

The registry, account ID, and IAM role ARNs in both workflows are placeholders. There
is no real AWS account behind this take-home to publish to, and the assignment does not
expect one. Both workflows are written to be correct, not to actually run against real
infrastructure. ECR was picked over GHCR, Harbor, or Artifact Registry so the app image
and the chart share one registry, not two.

## IaC (Terraform)

[iac/terraform/aws-eks/](iac/terraform/aws-eks/) builds a real EKS cluster (VPC, a
managed node group, the full setup) using the `terraform-aws-modules` registry modules,
then deploys the chart onto it from the private ECR repo the CI/CD pipeline publishes
to. This is the literal reading of the assignment's IaC ask: code that would cost real
money to run. So `plan` and `apply` were never run on purpose. Only `terraform init` and
`terraform validate` were run, and both pass cleanly with no AWS credentials involved.

```bash
cd iac/terraform/aws-eks
terraform init
terraform validate
```

## Version control strategy

- **Trunk based, `main` is protected.** Every change lands through a PR. The `validate`
  CI job (lint, unit tests, schema check) must pass before a merge.
- **The chart version is the release boundary, not a branch.** `Chart.yaml`'s `version`
  is bumped using semver: patch for template or values fixes, minor for new features,
  major for breaking changes to the values schema. This happens in the same PR as the
  change. The `publish` job fails the merge to `main` if that version is already in the
  registry, so the version bump is enforced, not just a convention people are supposed
  to remember.
- **`appVersion` tracks the app. `version` tracks the chart. They move on their own.** A
  chart only change, like a new probe option, bumps `version` without touching
  `appVersion`. A new model image bumps `appVersion` (usually just
  `values-<env>.yaml`'s `image.tag`) without needing to touch the chart at all.
- **Environments move forward through values files, not branches.** There is no
  `dev`, `staging`, or `prod` branch. One chart version moves from dev to staging to
  prod by pointing each environment's `helm upgrade` at that same, already published
  chart version, with its own values file. This avoids the usual problem of not knowing
  which branch is actually running in prod.
- **No secrets in git, ever.** This is enforced by how the chart is built, not just by a
  rule people are told to follow. See Secrets above.

## Outside the box ideas

Built already:

- **Model and app metadata comes from the platform itself.** `MODEL_VERSION` is set
  from `image.tag`, not typed in by hand. `app.kubernetes.io/version` carries the same
  value as a label, so `kubectl get pods -L app.kubernetes.io/version` answers "which
  model version is running" without calling the API at all.
- **One health contract every onboarded ML API must follow.** `probes.*` in
  `values.yaml`, plus a documented `/health` path, means the platform team defines what
  "ready" means once. No model team has to invent its own probes.
- **Resource defaults that care about cost.** Dev asks for 50m CPU and 64Mi memory.
  Prod asks for 250m and 256Mi, and turns on HPA (3 to 10 replicas). The defaults push
  toward not paying for dev or staging capacity nobody needs, without an MLE having to
  think about it.

What could be added next:

- **Progressive delivery, or canary releases.** The chart's `service` and `Deployment`
  selector already keep one release's Pods separate and clean. The next step would be a
  second, weighted Service (or a service mesh traffic split), driven by the same
  values-file pattern, for example `canary.weight: 10`. A canary rollout would still
  just mean "edit a values file", nothing new to learn.
- **GitOps with ArgoCD.** This chart already does not care how `helm upgrade` gets
  called. Pointing an ArgoCD `Application` at the published OCI chart, plus a values
  file per environment, is a drop in replacement for the CI `publish` job triggering
  deploys directly. Only who calls `helm` would change, nothing else.
- **Node level autoscaling with Karpenter.** `iac/terraform/aws-eks/` currently sizes a
  fixed EKS managed node group (`min_size`, `max_size`, `desired_size`). The HPA in this
  chart already handles pod level autoscaling, but nothing resizes the nodes themselves.
  Karpenter would provision right-sized (and spot-eligible) EC2 capacity directly
  against pods that cannot be scheduled, instead of a fixed pool of one instance type.
  Not added here because it is its own controller, with its own install and its own IAM
  setup. That is more than a take-home's node group needs.
- **Topology spread, or pod anti-affinity.** Right now prod's 3 to 10 replicas could
  all land on the same node, and nothing stops that. A `topologySpreadConstraints`
  block (or anti-affinity) would spread them across nodes or availability zones, so one
  node failing does not take out every replica at once. Not built because it needs to
  depend on the environment (dev runs a single replica, so spreading one pod means
  nothing), and that is more chart logic than a take-home needs.
- **A NetworkPolicy, default deny with explicit allow rules.** This would fit well with
  the chart's existing security choices: non-root, read-only root filesystem, no
  mounted token. Not shipped as a template because it only works if the cluster's CNI
  actually enforces NetworkPolicies. On a cluster where it does not, the policy would
  quietly do nothing, which is worse than not claiming the protection at all.

## Known gaps (said clearly, not hidden)

These are the places a real production setup would be different from this take-home.
Listed here on purpose, instead of leaving them for someone else to find:

- Model training happens inside the Docker build. A real pipeline would train once,
  version the artifact on its own (with MLflow, W&B, or a similar registry), and the
  serving image would only ever pull one specific artifact version.
- Liveness and readiness share one endpoint. This is only safe because this model loads
  at import time, before the process can answer any request. A model that loads slowly
  or lazily would need two separate signals.
- There is no scratch space (`emptyDir`) exposed as a value, even though
  `readOnlyRootFilesystem: true` is set. This app does not need one. A real model that
  needs to cache something at runtime would need that added.
- The CI/CD workflows and the Terraform code point at a placeholder AWS account and
  registry. Neither has been run against real cloud infrastructure. This is on purpose.
