# Demonstration snippet only.
#
# Shows *where* IaC would take over from `helm upgrade --install` on a real
# platform: same chart, same values-<env>.yaml files, just invoked through
# Terraform so the deploy is plannable and state-tracked alongside whatever
# else Terraform owns (the cluster itself, IAM, the ECR repo, ...).
#
# Deliberately not wired up to provision a real cluster or backend - no
# `backend "s3" {}`, no cloud provider blocks, no remote state. Running
# `terraform init && terraform plan` here talks only to the kubeconfig
# already on this machine (Minikube by default), which is the honest scope
# for a take-home: no real cloud spend, nothing to tear down.

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context != "" ? var.kube_context : null
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context != "" ? var.kube_context : null
  }
}

resource "helm_release" "ml_api" {
  name      = var.release_name
  namespace = var.namespace

  # Local path when chart_repository is unset (what actually runs against
  # Minikube for this take-home); an OCI registry reference once a real
  # private repo + credentials exist. Same resource either way.
  chart      = var.chart_repository != "" ? "ml-api" : "${path.module}/../../helm/ml-api"
  repository = var.chart_repository != "" ? var.chart_repository : null
  version    = var.chart_repository != "" ? var.chart_version : null

  values = [
    file("${path.module}/../../helm/ml-api/values-${var.environment}.yaml")
  ]

  create_namespace = true
}
