# EKS + Karpenter on AWS — Terraform

This repository provisions a production-ready Kubernetes cluster on AWS using:

- **Amazon EKS 1.33** inside a dedicated VPC
- **Karpenter v1.3** for node autoscaling
- **Graviton (arm64) and x86 (amd64) Spot instances** for optimal cost/performance

---

## Architecture Overview

```
┌───────────────────────────── Dedicated VPC (10.0.0.0/16) ──────────────────────────────┐
│                                                                                          │
│  Public subnets  (/20 × 3 AZs)  →  NAT Gateways / Load Balancers                       │
│  Private subnets (/20 × 3 AZs)  →  EKS Nodes (tagged for Karpenter discovery)          │
│                                                                                          │
│  ┌─────────────────── EKS Cluster (v1.33) ──────────────────────────────────────────┐   │
│  │                                                                                   │   │
│  │   System Managed Node Group (t3.large × 2, On-Demand, tainted)                   │   │
│  │     └── Karpenter controller (HA, 2 replicas)                                    │   │
│  │     └── CoreDNS / kube-proxy / VPC CNI                                           │   │
│  │                                                                                   │   │
│  │   Karpenter NodePool: arm64  (weight 100 — preferred)                            │   │
│  │     └── Graviton2/3/4 Spot → m6g, m7g, m8g, c6g, c7g, c8g, r6g, r7g, t4g       │   │
│  │                                                                                   │   │
│  │   Karpenter NodePool: x86   (weight 50)                                          │   │
│  │     └── Intel/AMD Spot → m5/m6i/m7i, c5/c6i/c7i, r5/r6i/r7i, and more          │   │
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

### 1. Clone and initialise

```bash
git clone <repo-url>
cd terraform/
terraform init
```

### 2. (Optional) Override defaults

Create a `terraform.tfvars` file:

```hcl
region       = "eu-west-1"
cluster_name = "my-company-eks"
```

All available variables and their defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `region` | `us-east-1` | AWS region |
| `cluster_name` | `startup-eks` | EKS cluster name |
| `cluster_version` | `1.33` | Kubernetes version |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR block |
| `karpenter_version` | `1.3.3` | Karpenter Helm chart version |
| `system_node_instance_type` | `t3.large` | Instance type for system node group |
| `system_node_count` | `2` | Node count for system node group |

### 3. Review and apply

```bash
terraform plan
terraform apply
```

Provisioning takes approximately **15–20 minutes** (EKS cluster creation dominates).

### 4. Configure kubectl

The `configure_kubectl` output contains the exact command you need:

```bash
terraform output -raw configure_kubectl | bash
# e.g. aws eks update-kubeconfig --name startup-eks --region us-east-1
```

Verify connectivity:

```bash
kubectl get nodes -o wide
kubectl get pods -n karpenter
```

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

When both platforms are present in the image, you can omit the `nodeSelector` entirely — Karpenter will prefer the arm64 (Graviton) NodePool due to its higher weight, choosing the cheaper, more performant option automatically.

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
| Workload nodes | Spot instances (both pools) | Up to 70% vs On-Demand |
| Graviton nodes | arm64 NodePool (preferred) | Additional 20–40% vs x86 On-Demand |
| System nodes | 2 × t3.large On-Demand | ~$0.17/hr total — never interrupted |
| Idle nodes | Karpenter consolidation (`WhenEmptyOrUnderutilized`) | Unused nodes terminated in ≤ 1 minute |
