###############################################################################
# Karpenter IAM — Controller role (IRSA) + Node role
###############################################################################

#------------------------------------------------------------------------------
# 1. IAM Role for the Karpenter controller pod (IRSA)
#    The controller needs EC2/pricing/SQS permissions to provision nodes.
#------------------------------------------------------------------------------

module "karpenter_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name                          = "${var.cluster_name}-karpenter-controller"
  attach_karpenter_controller_policy = true

  karpenter_controller_cluster_name       = module.eks.cluster_name
  karpenter_controller_node_iam_role_arns = [aws_iam_role.karpenter_node.arn]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["karpenter:karpenter"]
    }
  }
}

#------------------------------------------------------------------------------
# 2. IAM Role for EC2 nodes launched by Karpenter (node role)
#    Instances need this role to join the EKS cluster and pull images.
#------------------------------------------------------------------------------

data "aws_iam_policy_document" "karpenter_node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.${local.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "karpenter_node" {
  name               = "${var.cluster_name}-karpenter-node"
  assume_role_policy = data.aws_iam_policy_document.karpenter_node_assume.json

  tags = {
    Name = "${var.cluster_name}-karpenter-node"
  }
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile — attached to the EC2 instances launched by Karpenter
resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node"
  role = aws_iam_role.karpenter_node.name
}

#------------------------------------------------------------------------------
# 3. Grant the Karpenter node role access to the EKS cluster
#    (replaces the old aws-auth ConfigMap approach for EKS access mode)
#------------------------------------------------------------------------------

resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"

  depends_on = [module.eks]
}

#------------------------------------------------------------------------------
# 4. SQS queue for Spot interruption + Rebalance events
#------------------------------------------------------------------------------

resource "aws_sqs_queue" "karpenter_interruption" {
  # Name must match the cluster name — the IAM module scopes SQS access to
  # arn:aws:sqs:*:ACCOUNT:CLUSTER_NAME, so the queue name must equal the cluster name.
  name                      = var.cluster_name
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

# Explicit inline SQS policy — belt-and-suspenders in case the module's
# auto-generated policy doesn't cover the exact queue ARN.
#------------------------------------------------------------------------------
# 5. Instance-profile permissions for the Karpenter controller
#    Karpenter v1+ self-manages EC2 instance profiles. The stock
#    `attach_karpenter_controller_policy` flag does NOT include these actions,
#    so we add them explicitly to avoid the 403 AccessDenied on GetInstanceProfile.
#------------------------------------------------------------------------------

resource "aws_iam_role_policy" "karpenter_controller_instance_profile" {
  name = "karpenter-instance-profile-access"
  role = module.karpenter_irsa.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InstanceProfileManagement"
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:TagInstanceProfile",
          "iam:UntagInstanceProfile",
        ]
        # Scope to profiles whose name starts with the cluster name
        Resource = "arn:${local.partition}:iam::*:instance-profile/${var.cluster_name}*"
      },
      {
        Sid    = "PassNodeRole"
        Effect = "Allow"
        Action = "iam:PassRole"
        # Only allow passing the Karpenter node role to EC2
        Resource = aws_iam_role.karpenter_node.arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },
    ]
  })
}

#------------------------------------------------------------------------------
# 6. EC2 provisioning permissions for the Karpenter controller
#    The module's attach_karpenter_controller_policy scopes ec2:RunInstances
#    too narrowly in some module versions and may miss the launch-template
#    resource ARN that Karpenter v1 generates per EC2NodeClass.
#------------------------------------------------------------------------------

resource "aws_iam_role_policy" "karpenter_controller_ec2" {
  name = "karpenter-ec2-provisioning"
  role = module.karpenter_irsa.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # RunInstances touches many resource types — must allow all of them
        Sid    = "RunInstances"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          "arn:${local.partition}:ec2:*:${local.account_id}:launch-template/*",
          "arn:${local.partition}:ec2:*:${local.account_id}:subnet/*",
          "arn:${local.partition}:ec2:*:${local.account_id}:security-group/*",
          "arn:${local.partition}:ec2:*:${local.account_id}:network-interface/*",
          "arn:${local.partition}:ec2:*:${local.account_id}:instance/*",
          "arn:${local.partition}:ec2:*:${local.account_id}:volume/*",
          "arn:${local.partition}:ec2:*::image/*",      # AMIs are global (no account ID)
          "arn:${local.partition}:ec2:*:${local.account_id}:spot-instances-request/*",
        ]
      },
      {
        Sid    = "LaunchTemplateManagement"
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeLaunchTemplates",
          "ec2:CreateFleet",
        ]
        Resource = "*"
      },
      {
        Sid    = "NodeTermination"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate",
        ]
        Resource = "arn:${local.partition}:ec2:*:${local.account_id}:instance/*"
        Condition = {
          StringLike = {
            # Only terminate instances tagged as Karpenter-managed
            "ec2:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
    ]
  })
}


resource "aws_iam_role_policy" "karpenter_controller_sqs" {
  name = "karpenter-sqs-access"
  role = module.karpenter_irsa.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = [
        "sqs:GetQueueUrl",
        "sqs:GetQueueAttributes",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
      ]
      Resource = aws_sqs_queue.karpenter_interruption.arn
    }]
  })
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.karpenter_interruption.arn
      }
    ]
  })
}

# EventBridge rules that feed EC2 Spot/health events into the SQS queue
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.cluster_name}-spot-interruption"
  description = "Karpenter — EC2 Spot Instance Interruption Warning"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "rebalance" {
  name        = "${var.cluster_name}-rebalance"
  description = "Karpenter — EC2 Instance Rebalance Recommendation"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
}

resource "aws_cloudwatch_event_target" "rebalance" {
  rule      = aws_cloudwatch_event_rule.rebalance.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "instance_state" {
  name        = "${var.cluster_name}-instance-state"
  description = "Karpenter — EC2 Instance State-change Notification"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
}

resource "aws_cloudwatch_event_target" "instance_state" {
  rule      = aws_cloudwatch_event_rule.instance_state.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}
