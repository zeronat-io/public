# =============================================================================
# ZeroNAT Terraform Module — CloudWatch Log Shipping (optional)
# =============================================================================
#
# All resources in this file are created only when var.cloudwatch_log_group
# is set. When null (default), nothing here is created and there is no cost.
#
# Architecture:
#   1. Two CloudWatch Log Groups: /<group>/agent and /<group>/conntrackd
#   2. SSM Parameter Store holds the CloudWatch agent JSON config.
#   3. SSM State Manager association pushes the config to all ZeroNAT instances
#      via the pre-baked AmazonCloudWatch-ManageAgent SSM document. The SSM
#      agent is pre-installed on AL2023 and runs under the instance profile.
#
# IAM additions (in iam.tf) when this is active:
#   logs:CreateLogGroup, logs:CreateLogStream, logs:PutLogEvents,
#   logs:DescribeLogStreams — scoped to the log group prefix.
#   ssm:GetParameter — scoped to the config parameter path.
# =============================================================================

locals {
  enable_cw = var.cloudwatch_log_group != null
}


# =============================================================================
# CloudWatch Log Groups
# =============================================================================

resource "aws_cloudwatch_log_group" "agent" {
  count             = local.enable_cw ? 1 : 0
  name              = "/${var.cloudwatch_log_group}/agent"
  retention_in_days = var.cloudwatch_log_retention_days
  tags              = merge({ Name = "${var.name}-agent-logs" }, var.tags)
}

resource "aws_cloudwatch_log_group" "conntrackd" {
  count             = local.enable_cw ? 1 : 0
  name              = "/${var.cloudwatch_log_group}/conntrackd"
  retention_in_days = var.cloudwatch_log_retention_days
  tags              = merge({ Name = "${var.name}-conntrackd-logs" }, var.tags)
}


# =============================================================================
# SSM Parameter — CloudWatch agent configuration
# =============================================================================
#
# Stored at /${var.name}/cloudwatch-agent-config.
# The instance profile is granted ssm:GetParameter for this path (iam.tf).
#
# force_flush_interval=60s: ensures logs are shipped before instance termination
# when the OS shuts down gracefully. Covers spot reclaim and ASG scale-in.

resource "aws_ssm_parameter" "cw_agent_config" {
  count = local.enable_cw ? 1 : 0

  name = "/${var.name}/cloudwatch-agent-config"
  type = "String"

  value = jsonencode({
    logs = {
      force_flush_interval = 60
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path         = "/var/log/conntrackd.log"
              log_group_name    = "/${var.cloudwatch_log_group}/conntrackd"
              log_stream_name   = "{instance_id}"
              retention_in_days = var.cloudwatch_log_retention_days
            }
          ]
        }
        journald = {
          collect_list = [
            {
              log_group_name    = "/${var.cloudwatch_log_group}/agent"
              log_stream_name   = "{instance_id}"
              units             = ["zeronat-agent.service"]
              retention_in_days = var.cloudwatch_log_retention_days
            }
          ]
        }
      }
    }
  })

  tags = merge({ Name = "${var.name}-cw-agent-config" }, var.tags)
}


# =============================================================================
# SSM State Manager Association — pushes CW agent config to instances
# =============================================================================
#
# Targets all instances tagged with the ZeroNAT group tag (applied to both A
# and B in main.tf). Works in both single and cluster modes.
#
# On first association application (~5 min after instance start), the SSM agent
# runs amazon-cloudwatch-agent-ctl, applies the config from SSM, and restarts
# the CloudWatch agent. Re-applies every 30 days to recover from config drift.

resource "aws_ssm_association" "cw_agent" {
  count = local.enable_cw ? 1 : 0

  name             = "AmazonCloudWatch-ManageAgent"
  association_name = "${var.name}-cw-agent"

  # Re-apply monthly — handles replacement instances joining the group.
  schedule_expression = "rate(30 days)"

  # Target by the group tag (applied to all ZeroNAT instances in main.tf).
  targets {
    key    = "tag:${var.group_tag_key}"
    values = [var.name]
  }

  parameters = {
    action                        = "configure"
    mode                          = "ec2"
    optionalConfigurationSource   = "ssm"
    optionalConfigurationLocation = aws_ssm_parameter.cw_agent_config[0].name
    optionalRestart               = "yes"
  }

  depends_on = [
    aws_ssm_parameter.cw_agent_config,
    aws_cloudwatch_log_group.agent,
    aws_cloudwatch_log_group.conntrackd,
  ]
}
