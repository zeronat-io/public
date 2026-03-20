# =============================================================================
# ZeroNAT Terraform Module — Outputs
# =============================================================================
#
# All outputs are always defined. Instance B outputs use try() to return null
# in single mode — this avoids forcing callers to check mode before referencing
# outputs.
# =============================================================================


# =============================================================================
# Instance IDs
# =============================================================================

output "instance_a_id" {
  description = "Instance A ID (always present)."
  value       = aws_instance.a.id
}

output "instance_b_id" {
  description = "Instance B ID. Null in single mode."
  value       = try(aws_instance.b[0].id, null)
}


# =============================================================================
# Private IPs
# =============================================================================

output "instance_a_private_ip" {
  description = "Instance A private IP address."
  value       = aws_instance.a.private_ip
}

output "instance_b_private_ip" {
  description = "Instance B private IP address. Null in single mode."
  value       = try(aws_instance.b[0].private_ip, null)
}


# =============================================================================
# ENI IDs (the ENIs that routes point to)
# =============================================================================

output "instance_a_eni_id" {
  description = "Instance A primary ENI ID. Routes point to this ENI."
  value       = aws_instance.a.primary_network_interface_id
}

output "instance_b_eni_id" {
  description = "Instance B primary ENI ID. Null in single mode."
  value       = try(aws_instance.b[0].primary_network_interface_id, null)
}


# =============================================================================
# Security Group
# =============================================================================

output "security_group_id" {
  description = "Security group ID. Use to attach additional rules or reference from other SGs."
  value       = aws_security_group.zeronat.id
}


# =============================================================================
# IAM
# =============================================================================

output "iam_role_arn" {
  description = "IAM role ARN for policy auditing. Null when using an externally managed instance profile."
  value       = try(aws_iam_role.zeronat[0].arn, null)
}

output "iam_role_name" {
  description = "IAM role name. Use to attach additional policies. Null when using an externally managed instance profile."
  value       = try(aws_iam_role.zeronat[0].name, null)
}


# =============================================================================
# Mode
# =============================================================================

output "mode" {
  description = "Deployment mode (\"single\" or \"cluster\"). Lets callers branch without re-deriving."
  value       = var.mode
}
