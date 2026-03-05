#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — EKS + Karpenter cluster bootstrap
#
# Captures every manual CLI step performed during initial cluster setup.
# Run this once from the repo root to go from zero to a working cluster.
#
# Prerequisites (must be installed and on PATH):
#   aws   >= 2.x  (configured with a profile that has AdministratorAccess)
#   terraform >= 1.6
#   kubectl, helm
# =============================================================================

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Config (override via env vars) ────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-eu-central-1}"
CLUSTER_NAME="${CLUSTER_NAME:-startup-eks}"
TF_DIR="${TF_DIR:-$(cd "$(dirname "$0")/../terraform" && pwd)}"

# =============================================================================
# 1. Preflight checks
# =============================================================================
info "Checking required tools..."
for cmd in aws terraform kubectl helm; do
  command -v "$cmd" &>/dev/null || die "'$cmd' not found — please install it first."
done

info "Checking AWS credentials..."
aws sts get-caller-identity --region "$AWS_REGION" \
  || die "AWS credentials not configured. Run 'aws configure' or set AWS_PROFILE."

# =============================================================================
# 2. One-time AWS account prerequisites
# =============================================================================

# ── EC2 Spot service-linked role ──────────────────────────────────────────────
# Must exist in the account BEFORE any Spot instances can be launched.
# Karpenter cannot create this itself — it requires iam:CreateServiceLinkedRole
# on the account root / admin principal.
info "Ensuring AWSServiceRoleForEC2Spot exists..."
if aws iam get-role --role-name AWSServiceRoleForEC2Spot \
     --region "$AWS_REGION" &>/dev/null; then
  info "  AWSServiceRoleForEC2Spot already exists — skipping."
else
  aws iam create-service-linked-role \
    --aws-service-name spot.amazonaws.com \
    --region "$AWS_REGION"
  info "  AWSServiceRoleForEC2Spot created."
fi

# =============================================================================
# 3. Terraform — init + apply
# =============================================================================
info "Running terraform init..."
cd "$TF_DIR"
terraform init -upgrade

info "Running terraform apply..."
terraform apply -auto-approve

# =============================================================================
# 4. Configure kubectl
# =============================================================================
info "Updating kubeconfig for cluster '$CLUSTER_NAME'..."
aws eks update-kubeconfig \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION"

# =============================================================================
# 5. Verify cluster + Karpenter
# =============================================================================
info "Waiting for system nodes to be Ready..."
kubectl wait nodes \
  --selector role=system \
  --for condition=Ready \
  --timeout=300s

info "Checking Karpenter pod status..."
kubectl rollout status deployment/karpenter \
  -n karpenter \
  --timeout=180s

info "NodePool + EC2NodeClass status:"
kubectl get nodepool,ec2nodeclass -o wide

# =============================================================================
# Done
# =============================================================================
echo ""
info "Bootstrap complete ✓"
echo ""
echo "  Cluster endpoint : $(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.endpoint' --output text)"
echo "  Karpenter logs   : kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --follow"
echo "  Node status      : kubectl get nodes -L karpenter.sh/nodepool,topology.kubernetes.io/zone"
