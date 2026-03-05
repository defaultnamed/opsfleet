variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster (and used as a tag prefix for Karpenter discovery)."
  type        = string
  default     = "startup-eks"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.35"
}

variable "vpc_cidr" {
  description = "CIDR block for the new dedicated VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version to install."
  type        = string
  default     = "1.3.3"
}

variable "system_node_instance_type" {
  description = "EC2 instance type for the system managed node group (runs Karpenter + core add-ons)."
  type        = string
  default     = "t3.small"
}

variable "system_node_count" {
  description = "Desired number of nodes in the system managed node group."
  type        = number
  default     = 1
}
