###############################################################################
# VPC
#
#  Public subnets  (2 AZs) → NAT Gateway (AZ-a only) + external Load Balancer
#  Private subnets (2 AZs) → EKS nodes + pods  (EKS requires ≥ 2 AZs)
#
#  Cost note: single NAT GW shared by both private subnets. Cross-AZ data
#  transfer from AZ-b costs ~$0.01/GB but saves ~$32/mo vs a second NAT GW.
###############################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.19"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs = local.azs   # 2 AZs — EKS minimum requirement

  # One public subnet per AZ (needed so the NAT GW can reach both AZs)
  public_subnets = [
    cidrsubnet(var.vpc_cidr, 4, 0),   # AZ-a — hosts the NAT GW + external LB
    cidrsubnet(var.vpc_cidr, 4, 1),   # AZ-b — external LB only
  ]

  # Two private subnets (one per AZ) for EKS nodes + pods
  private_subnets = [
    cidrsubnet(var.vpc_cidr, 4, 4),   # AZ-a
    cidrsubnet(var.vpc_cidr, 4, 5),   # AZ-b
  ]

  # Single NAT GW — cheapest option; both private subnets route through it
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tag public subnets so AWS LBC places the external LB here
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  # Tag private subnets for Karpenter node discovery + internal LB support
  private_subnet_tags = merge(
    { "kubernetes.io/role/internal-elb" = "1" },
    local.karpenter_tag
  )
}
