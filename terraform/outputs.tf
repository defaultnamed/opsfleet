###############################################################################
# Outputs
###############################################################################

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "API server endpoint URL for the EKS cluster."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate for the cluster (used by kubectl)."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster."
  value       = module.eks.cluster_version
}

output "vpc_id" {
  description = "ID of the dedicated VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "ID of the single private subnet (EKS nodes run here)."
  value       = module.vpc.private_subnets
}

output "karpenter_node_role_arn" {
  description = "ARN of the IAM role attached to Karpenter-managed EC2 nodes."
  value       = aws_iam_role.karpenter_node.arn
}

output "karpenter_controller_role_arn" {
  description = "ARN of the IRSA role used by the Karpenter controller pod."
  value       = module.karpenter_irsa.iam_role_arn
}

output "karpenter_interruption_queue_url" {
  description = "SQS queue URL used by Karpenter for Spot interruption handling."
  value       = aws_sqs_queue.karpenter_interruption.url
}

output "configure_kubectl" {
  description = "Run this command to configure kubectl for the new cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}
