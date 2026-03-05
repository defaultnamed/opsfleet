###############################################################################
# EKS Cluster
###############################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # Place the cluster in the dedicated VPC
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Enable public + private API endpoint (public only for convenience in a POC;
  # tighten to private-only for production)
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # Enable IRSA (IAM Roles for Service Accounts) for Karpenter and other add-ons
  enable_irsa = true

  # Managed EKS add-ons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true           # Must be ready before nodes join
      configuration_values = jsonencode({
        env = {
          # Enable prefix delegation for higher pod density
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  ###############################################################################
  # System managed node group — hosts Karpenter + critical add-ons
  # These are on-demand nodes that Karpenter itself must NOT manage.
  ###############################################################################
  eks_managed_node_groups = {
    system = {
      name           = "system"
      instance_types = [var.system_node_instance_type]

      min_size     = 1
      max_size     = 1
      desired_size = var.system_node_count

      # Only On-Demand so these nodes are never interrupted
      capacity_type = "ON_DEMAND"

      ami_type = "AL2023_x86_64_STANDARD"

      labels = {
        role = "system"
      }

      # Taint the system nodes so only critical workloads (Karpenter, CoreDNS, etc.)
      # land here. Regular application pods instead go to Karpenter-managed nodes.
      taints = {
        critical_addons = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      # Allow Karpenter to add the required node role to aws-auth
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    }
  }

  # Tag the cluster's primary security group for Karpenter discovery
  node_security_group_tags = local.karpenter_tag

  # Grant the IAM user/role running Terraform cluster-admin access
  enable_cluster_creator_admin_permissions = true

  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}
