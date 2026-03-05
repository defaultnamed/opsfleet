###############################################################################
# Core providers and shared data sources
###############################################################################

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.cluster_name
      ManagedBy   = "terraform"
    }
  }
}

# Kubernetes and Helm providers are configured after the cluster is created,
# using the cluster's CA data and token obtained via the AWS provider.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
}

###############################################################################
# Data sources
###############################################################################

data "aws_availability_zones" "available" {
  # Only use AZs that support EKS
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

###############################################################################
# Local values
###############################################################################

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix

  # Pick first 3 AZs for the VPC
  azs = slice(data.aws_availability_zones.available.names, 0, 2)   # 2 AZs required by EKS

  # Karpenter discovery tag — used on subnets and security groups
  karpenter_tag = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}
