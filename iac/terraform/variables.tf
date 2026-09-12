variable "environment" {
  description = "Which values-<environment>.yaml overlay to deploy. Matches the environments the chart already ships (dev/staging/prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "kubeconfig_path" {
  description = "Path to the kubeconfig for the target cluster. Points at Minikube by default; swap for a real cluster's kubeconfig (EKS, etc.) without changing anything else here."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Context inside the kubeconfig to use. Empty string uses whatever context is currently active."
  type        = string
  default     = ""
}

variable "chart_version" {
  description = "Chart version to install, matching the version published by the CI/CD pipeline in .github/workflows/helm-chart.yml. Only meaningful when chart_repository is set (i.e. not a local path)."
  type        = string
  default     = "0.1.0"
}

variable "chart_repository" {
  description = <<-EOT
    Where to pull the chart from.
      - "" (default): deploy straight from the local helm/ml-api/ directory. This is
        what actually works against Minikube without any real cloud credentials.
      - "oci://<account>.dkr.ecr.<region>.amazonaws.com/helm-charts/ml-api": the private
        ECR repository the CI/CD pipeline publishes to. Requires AWS credentials capable
        of an ECR OCI login, which this snippet deliberately does not wire up - it
        exists to show *where* Terraform plugs in, not to be applied against a real
        account.
  EOT
  type        = string
  default     = ""
}

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "ml-api"
}

variable "namespace" {
  description = "Kubernetes namespace to deploy into."
  type        = string
  default     = "default"
}
