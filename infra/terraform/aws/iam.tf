# =============================================================================
# ZeroNAT Terraform Module — IAM Role + Instance Profile
# =============================================================================
#
# Creates an IAM role, inline policy, and instance profile for the ZeroNAT
# agent — UNLESS var.iam_instance_profile_name is set, in which case the caller
# manages IAM externally and all resources in this file are skipped.
#
# The policy follows least-privilege and varies by deployment mode:
#
#   BOTH modes (base):
#     ec2:DescribeInstances   — reads own group tag at boot; peer discovery in cluster mode
#     ec2:DescribeRouteTables — agent discovers managed route tables at boot
#     ec2:ReplaceRoute        — agent takes over existing 0.0.0.0/0 routes at boot
#     ec2:CreateRoute         — agent creates 0.0.0.0/0 if no existing route
#     cloudwatch:GetMetricData — CPU credit monitoring for T-series instances
#
# Routes are NOT created by Terraform. Instance A boots with
# ZERONAT_TAKEOVER_ON_BOOT=true and the agent creates/replaces routes once
# all services are ready — ensuring zero-downtime deployments.
#
# Trust chain (when module manages IAM):
#
#   EC2 instance
#     └─ Instance Profile (aws_iam_instance_profile.zeronat)
#          └─ IAM Role (aws_iam_role.zeronat)
#               └─ Inline Policy (aws_iam_role_policy.zeronat)
#                    └─ ec2:Describe*, ec2:ReplaceRoute, ec2:CreateRoute, cloudwatch:GetMetricData
#
# =============================================================================

locals {
  # When the caller provides an existing instance profile, skip creating IAM resources.
  # Otherwise the module creates its own role, policy, and profile.
  create_iam = var.iam_instance_profile_name == null

  # Resolve the instance profile name: caller-provided or module-created.
  instance_profile_name = (
    var.iam_instance_profile_name != null
    ? var.iam_instance_profile_name
    : aws_iam_instance_profile.zeronat[0].name
  )

  # CloudWatch Logs permissions are added only when cloudwatch_log_group is set
  # and the module is managing IAM.
  create_cw_logs_policy = local.create_iam && var.cloudwatch_log_group != null
}


# =============================================================================
# IAM Role — assumed by EC2 instances
# =============================================================================

resource "aws_iam_role" "zeronat" {
  count = local.create_iam ? 1 : 0 # Skipped when caller provides their own instance profile

  name = "${var.name}-zeronat"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = merge({ Name = "${var.name}-zeronat" }, var.tags)
}


# =============================================================================
# IAM Inline Policy — permissions vary by mode
# =============================================================================

resource "aws_iam_role_policy" "zeronat" {
  count = local.create_iam ? 1 : 0 # Skipped when caller provides their own instance profile

  name = "${var.name}-zeronat"
  role = aws_iam_role.zeronat[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      # --- Base permissions (both modes) ---
      # DescribeInstances: agent reads its own group tag at boot (ReadGroupTag)
      #   and discovers peers in cluster mode — agent/discovery/discovery.go
      #   Note: Describe* actions cannot be scoped to specific resources (AWS limitation).
      #   Currently enforced at application level (agent filters by vpc-id).
      # DescribeRouteTables: agent discovers managed route tables via group tag at boot
      [
        {
          Sid      = "DescribeForDiscovery"
          Effect   = "Allow"
          Action   = ["ec2:DescribeInstances", "ec2:DescribeRouteTables"]
          Resource = "*"
        }
      ],

      # ReplaceRoute: agent takes over existing 0.0.0.0/0 routes at boot (TAKEOVER_ON_BOOT)
      #   See agent/failover/failover.go:161 (NetworkInterfaceId)
      # CreateRoute: agent creates 0.0.0.0/0 if no existing default route exists
      # Scoped to exactly the route tables managed by this module — prevents a
      # compromised instance from redirecting traffic in unrelated VPCs/subnets.
      [
        {
          Sid    = "RouteTableMutation"
          Effect = "Allow"
          Action = ["ec2:ReplaceRoute", "ec2:CreateRoute"]
          Resource = [
            for id in var.route_table_ids :
            "arn:aws:ec2:*:*:route-table/${id}"
          ]
        }
      ],

      # --- EIP failover (optional: only when EIP is managed) ---
      # AssociateAddress: agent moves the shared EIP to itself during failover
      # DisassociateAddress: cleanup if needed
      # DescribeAddresses: agent checks current EIP association
      local.manage_eip ? [
        {
          Sid      = "EIPFailover"
          Effect   = "Allow"
          Action   = ["ec2:AssociateAddress", "ec2:DisassociateAddress", "ec2:DescribeAddresses"]
          Resource = "*"
        }
      ] : [],

      # --- CloudWatch metrics (CPU credit monitoring on T-series) ---
      # See agent/metrics/cloud/aws.go — calls GetMetricData
      [
        {
          Sid      = "CloudWatchMetrics"
          Effect   = "Allow"
          Action   = ["cloudwatch:GetMetricData"]
          Resource = "*"
        }
      ],

      # --- CloudWatch Logs (optional log shipping) ---
      # Added only when var.cloudwatch_log_group is set.
      local.create_cw_logs_policy ? [
        {
          Sid    = "CloudWatchLogs"
          Effect = "Allow"
          Action = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents",
            "logs:DescribeLogStreams",
          ]
          Resource = "arn:aws:logs:*:*:log-group:/${var.cloudwatch_log_group}/*:*"
        },
        {
          # SSM GetParameter: CW agent fetches its config from SSM at startup.
          # Scoped to the predictable parameter path written by cloudwatch.tf.
          Sid      = "SSMGetCWAgentConfig"
          Effect   = "Allow"
          Action   = ["ssm:GetParameter"]
          Resource = "arn:aws:ssm:*:*:parameter/${var.name}/cloudwatch-agent-config"
        }
      ] : [],
    )
  })
}


# =============================================================================
# Instance Profile — links the role to EC2 instances
# =============================================================================

resource "aws_iam_instance_profile" "zeronat" {
  count = local.create_iam ? 1 : 0 # Skipped when caller provides their own instance profile

  name = "${var.name}-zeronat"
  role = aws_iam_role.zeronat[0].name

  tags = merge({ Name = "${var.name}-zeronat" }, var.tags)
}
