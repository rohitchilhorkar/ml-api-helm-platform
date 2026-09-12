variable "aws_region" {
  description = "AWS region for the cluster."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "ml-api-cluster"
}

variable "environment" {
  description = "Which values-<environment>.yaml overlay to deploy."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "chart_version" {
  description = "Chart version to install from the private ECR OCI repo (the version published by .github/workflows/helm-chart.yml)."
  type        = string
  default     = "0.1.0"
}

variable "ecr_account_id" {
  description = "AWS account ID hosting the private ECR chart repository."
  type        = string
  default     = "123456789012"
}
