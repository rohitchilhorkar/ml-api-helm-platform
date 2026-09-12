# Builds a real cloud cluster and deploys the chart onto it.
# Not applied against a real AWS account for this take-home.
#
# `terraform validate` passes, checked without AWS credentials.
# `plan` and `apply` are not run here, because they would create a billed
# EKS control plane and an EC2 node group.

provider "aws" {
  region = var.aws_region
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.30"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 3
      desired_size   = 2
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

# This is the actual chart deployment. Same chart, same values files, same
# `helm_release` resource type that Helm's own Terraform provider gives us.
# It just points at the private ECR OCI repo that .github/workflows/helm-chart.yml
# publishes to, instead of a local path, and logs in to the EKS cluster built
# above, instead of a local kubeconfig.
resource "helm_release" "ml_api" {
  name             = "ml-api"
  namespace        = "default"
  create_namespace = true

  chart      = "ml-api"
  repository = "oci://${var.ecr_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/helm-charts"
  version    = var.chart_version

  values = [
    file("${path.module}/../../../helm/ml-api/values-${var.environment}.yaml")
  ]

  depends_on = [module.eks]
}
