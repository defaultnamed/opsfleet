# EKS + Karpenter on AWS — Terraform

This repository provisions a production-ready Kubernetes cluster on AWS using:

- **Amazon EKS 1.35** inside a dedicated VPC
- **Karpenter v1.3** for node autoscaling
- **Graviton (arm64) and x86 (amd64) Spot instances** for optimal cost/performance

---

## Architecture Overview

```
┌───────────────────────────── Dedicated VPC (10.0.0.0/16) ──────────────────────────────┐
│                                                                                          │
│  Public subnets  (/20 × 2 AZs)  →  NAT Gateways / Load Balancers                       │
│  Private subnets (/20 × 2 AZs)  →  EKS Nodes (tagged for Karpenter discovery)          │
│                                                                                          │
│  ┌─────────────────── EKS Cluster (v1.33) ──────────────────────────────────────────┐   │
│  │                                                                                   │   │
│  │   System Managed Node Group (t3.large, On-Demand, tainted)                   │   │
│  │     └── Karpenter controller (1 replicas)                                    │   │
│  │     └── CoreDNS / kube-proxy / VPC CNI                                           │   │
│  │                                                                                   │   │
│  │   Karpenter NodePool: x86   (weight 100 — preferred)                             │   │
│  │     └── Intel/AMD Spot → t2, t3                                                  │   │
│  │                                                                                  │   │
│  │   Karpenter NodePool: arm64  (weight 50)                                         │   │
│  │     └── Graviton Spot → t4g                                                      │   │
│  │                                                                                   │   │
│  └───────────────────────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

| Tool | Version |
|------|---------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | ≥ 1.8 |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | v2 |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | ≥ 1.29 |
| AWS credentials with `AdministratorAccess` (or scoped EKS/EC2/IAM permissions) | — |

---

## Quick Start

A `bootstrap.sh` script is provided to automate everything from the prerequisites to verifying the cluster. It will:
1. Ensure the required `AWSServiceRoleForEC2Spot` service-linked role is created in your account.
2. Initialise and apply the Terraform configuration.
3. Update your local kubeconfig.
4. Verify the cluster nodes and Karpenter deployment.

```bash
git clone <repo-url>
cd <repo-dir>

# Overrides (optional):
# export AWS_REGION="us-east-1"
# export CLUSTER_NAME="my-company-eks"

./scripts/bootstrap.sh
```

*(Note: Provisioning takes approximately **15–20 minutes** as the EKS cluster creation dominates the setup time.)*

---

## Developer Guide — Running Pods on Specific Architectures

Karpenter will automatically launch the right node based on the `nodeSelector` or `nodeAffinity` you set on your workload. **No pre-existing node required** — Karpenter provisions one on demand.

### Option A: `nodeSelector` (simple, declarative)

#### Run on Graviton (arm64)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app-arm64
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      nodeSelector:
        kubernetes.io/arch: arm64          # → Karpenter arm64 NodePool
      containers:
        - name: my-app
          image: my-registry/my-app:latest  # must be a multi-arch or arm64 image
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
```

#### Run on x86 (amd64)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app-x86
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64          # → Karpenter x86 NodePool
      containers:
        - name: my-app
          image: my-registry/my-app:latest
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
```

---

### Option B: `nodeAffinity` (flexible, with fallback)

Use `preferredDuringSchedulingIgnoredDuringExecution` when you'd *like* Graviton but can fall back to x86:

```yaml
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: kubernetes.io/arch
                operator: In
                values: ["arm64"]   # Prefer Graviton …
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: kubernetes.io/arch
                operator: In
                values: ["arm64", "amd64"]  # … but x86 is also acceptable
```

---

### Option C: Quick one-off pod (testing)

```bash
# On Graviton
kubectl run test-arm \
  --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/arch":"arm64"},"restartPolicy":"Never"}}' \
  -- uname -m
# Expected output: aarch64

# On x86
kubectl run test-x86 \
  --image=public.ecr.aws/amazonlinux/amazonlinux:2023 \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/arch":"amd64"},"restartPolicy":"Never"}}' \
  -- uname -m
# Expected output: x86_64
```

> **Tip:** Use `kubectl get events --field-selector source=karpenter` to watch Karpenter spin up a node in real time.

---

### Multi-arch images

For workloads that can run on either architecture, build and push a **multi-platform manifest** with Docker Buildx:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --push \
  -t my-registry/my-app:latest .
```

When both platforms are present in the image, you can omit the `nodeSelector` entirely — Karpenter will prefer the x86 NodePool due to its higher weight, choosing the broader compatibility option automatically.

---

## Teardown

```bash
# Remove Karpenter-managed nodes first (so Karpenter cleans up EC2 instances)
kubectl delete nodepools --all
kubectl delete ec2nodeclasses --all

# Then destroy all Terraform resources
terraform destroy
```

---

## Cost Notes

| Component | Strategy | Estimated savings |
|-----------|----------|-------------------|
| Workload nodes | Spot instances (t2, t3, t4g) | Up to 70% vs On-Demand |
| Graviton nodes | arm64 NodePool | Additional 20–40% vs x86 On-Demand |
| System nodes | 1 × t3.large On-Demand | ~$0.17/hr total — never interrupted |
| Idle nodes | Karpenter consolidation (`WhenEmptyOrUnderutilized`) | Unused nodes terminated in ≤ 1 minute |
