###############################################################################
# Karpenter Node Classes and Node Pools
#
# EC2NodeClass   — AWS-specific settings (AMI family, subnets, security groups)
# NodePool (x86) — amd64 workloads, Spot preferred, broad instance diversity
# NodePool (arm64) — Graviton workloads, Spot preferred, higher weight for cost
###############################################################################

#------------------------------------------------------------------------------
# EC2NodeClass — shared by both NodePools
#------------------------------------------------------------------------------

resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      # AMI selection — alias format is required in Karpenter v1.x
      # al2023@latest always picks the latest AL2023 AMI for the cluster's k8s version
      amiSelectorTerms:
        - alias: al2023@latest

      # Discover subnets tagged with karpenter.sh/discovery=<cluster-name>
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}

      # Discover security groups tagged with karpenter.sh/discovery=<cluster-name>
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}

      # IAM role that Karpenter-managed nodes will assume
      role: ${aws_iam_role.karpenter_node.name}

      # EBS root volume settings — gp3 is cheaper and more performant than gp2
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 50Gi
            volumeType: gp3
            encrypted: true

      # Instance metadata settings — IMDSv2 only for security
      metadataOptions:
        httpEndpoint: enabled
        httpProtocolIPv6: disabled
        httpPutResponseHopLimit: 1      # IMDSv2: 1 hop = pods cannot reach IMDS
        httpTokens: required            # Enforce IMDSv2

      tags:
        Name: "${var.cluster_name}-karpenter-node"
        ManagedBy: karpenter
  YAML

  depends_on = [helm_release.karpenter]
}

#------------------------------------------------------------------------------
# NodePool — x86 (amd64)
# Covers mainstream Intel/AMD instance families across generations.
# Both Spot and On-Demand are allowed; Karpenter will prefer Spot.
#------------------------------------------------------------------------------

resource "kubectl_manifest" "karpenter_nodepool_x86" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: x86
    spec:
      # Higher weight → tried first. x86 is the default for broad compatibility.
      weight: 100

      template:
        metadata:
          labels:
            node.kubernetes.io/nodepool: x86
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default

          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]

            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]

            # Cheapest
            - key: karpenter.k8s.aws/instance-family
              operator: In
              values:
                - t2
                - t3

            - key: karpenter.k8s.aws/instance-size
              operator: In
              values: ["nano", "micro", "small"]

            - key: kubernetes.io/os
              operator: In
              values: ["linux"]

          # Drift / consolidation settings
          expireAfter: 720h   # Replace nodes after 30 days to stay patched

      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m

      # Hard caps to prevent runaway scaling
      limits:
        cpu: "100"
        memory: 400Gi
  YAML

  depends_on = [kubectl_manifest.karpenter_node_class]
}

#------------------------------------------------------------------------------
# NodePool — arm64 (Graviton)
# AWS Graviton3/4 instances: up to 40% better price-performance vs x86.
# Higher weight means Karpenter tries this pool first for multi-arch workloads.
#------------------------------------------------------------------------------

resource "kubectl_manifest" "karpenter_nodepool_arm64" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: arm64
    spec:
      # Higher weight → preferred over x86 for workloads that support both archs
      weight: 100

      template:
        metadata:
          labels:
            node.kubernetes.io/nodepool: arm64
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default

          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["arm64"]

            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]

            # Cheapest 
            - key: karpenter.k8s.aws/instance-family
              operator: In 
              values:
                - t4g

            - key: karpenter.k8s.aws/instance-size
              operator: In
              values: ["nano", "micro", "small"]

            - key: kubernetes.io/os
              operator: In
              values: ["linux"]

          expireAfter: 720h

      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m

      limits:
        cpu: "100"
        memory: 400Gi
  YAML

  depends_on = [kubectl_manifest.karpenter_node_class]
}
