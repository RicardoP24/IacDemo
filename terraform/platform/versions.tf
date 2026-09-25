terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }

  backend "s3" {
    key          = "iacdemo/platform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

# The platform stack reads the infra stack's outputs from the same state bucket.
data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "iacdemo/infra.tfstate"
    region = var.region
  }
}

locals {
  infra        = data.terraform_remote_state.infra.outputs
  cluster_name = local.infra.cluster_name

  # Short-lived token from the AWS CLI; nothing is stored in the state.
  kube_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = concat(
      ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.region],
      var.assume_role_arn == null ? [] : ["--role-arn", var.assume_role_arn],
    )
  }
}

provider "aws" {
  region = var.region

  dynamic "assume_role" {
    for_each = var.assume_role_arn == null ? [] : [var.assume_role_arn]
    content {
      role_arn     = assume_role.value
      session_name = "iacdemo-terraform"
    }
  }

  default_tags {
    tags = {
      Project     = "iacdemo"
      Environment = "demo"
      ManagedBy   = "terraform"
      Stack       = "platform"
    }
  }
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = local.kube_exec.api_version
    command     = local.kube_exec.command
    args        = local.kube_exec.args
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec                   = local.kube_exec
  }
}
