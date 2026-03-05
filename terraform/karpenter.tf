###############################################################################
# Karpenter — Helm installation
###############################################################################

resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version

  # Wait for chart + CRDs to be ready before we apply NodePool / EC2NodeClass
  wait    = true
  timeout = 600

  set {
    name  = "settings.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = module.eks.cluster_endpoint
  }

  set {
    name  = "settings.interruptionQueue"
    value = aws_sqs_queue.karpenter_interruption.name
  }

  # Bind the controller SA to the IRSA role
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter_irsa.iam_role_arn
  }

  # Run Karpenter on the tainted system nodes
  set {
    name  = "tolerations[0].key"
    value = "CriticalAddonsOnly"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  set {
    name  = "nodeSelector.role"
    value = "system"
  }

  set {
    name  = "replicas"
    value = "1"
  }

  depends_on = [
    module.eks,
    module.karpenter_irsa,
    aws_iam_instance_profile.karpenter_node,
    aws_eks_access_entry.karpenter_node,
    aws_sqs_queue.karpenter_interruption,
  ]
}
