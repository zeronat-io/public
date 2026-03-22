# =============================================================================
# ZeroNAT Terraform Module — Input Variables
# =============================================================================
#
# Variables are grouped into four categories:
#   1. Required — caller must always provide these
#   2. Mode selection — controls single vs cluster topology
#   3. Cluster-only — required/relevant only when mode = "cluster"
#   4. Optional — sensible defaults matching the ZeroNAT agent defaults
#
# Default values for ports and intervals are kept in sync with the Go agent.
# Cross-references to agent source are noted inline.
# =============================================================================


# =============================================================================
# Required Variables (no defaults — caller must provide)
# =============================================================================

variable "name" {
  description = "Resource name prefix. In cluster mode, also used as the group tag value for peer discovery."
  type        = string

  validation {
    condition     = length(var.name) > 0
    error_message = "name must not be empty."
  }
}

variable "vpc_id" {
  description = "VPC to deploy into. Used for security group creation."
  type        = string
}

variable "instance_a" {
  description = "Instance A configuration (always created). In single mode this is the only instance. In cluster mode it is the initial active node."
  type = object({
    ami_id    = string
    subnet_id = string
  })
}

variable "route_table_ids" {
  description = "Private-subnet route tables to manage. Tagged with the group tag for agent discovery. The agent creates/replaces the 0.0.0.0/0 route at boot (via ZERONAT_TAKEOVER_ON_BOOT)."
  type        = list(string)

  validation {
    condition     = length(var.route_table_ids) >= 1
    error_message = "At least one route table ID is required."
  }
}

variable "active_route_table_ids" {
  description = <<-EOT
    Subset of route_table_ids that should be actively managed (route takeover
    applied at boot). Defaults to all of route_table_ids when null. Use this for
    gradual migration from AWS NAT Gateway: start with one subnet, verify, then
    expand. Route tables in route_table_ids but NOT in active_route_table_ids
    will still be tagged for discovery and shown in the dashboard, but the agent
    will not claim their routes.
  EOT
  type    = list(string)
  default = null

  validation {
    condition = var.active_route_table_ids == null || alltrue([
      for rt in coalesce(var.active_route_table_ids, []) : contains(var.route_table_ids, rt)
    ])
    error_message = "active_route_table_ids must be a subset of route_table_ids."
  }
}


# =============================================================================
# Mode Selection
# =============================================================================

variable "mode" {
  description = "Deployment mode. \"single\" for a standalone NAT instance, \"cluster\" for an HA pair with automatic failover."
  type        = string
  default     = "single"

  validation {
    condition     = contains(["single", "cluster"], var.mode)
    error_message = "mode must be \"single\" or \"cluster\"."
  }
}


# =============================================================================
# Cluster-Only Variables (required when mode = "cluster", ignored in single)
# =============================================================================

variable "instance_b" {
  description = "Instance B configuration (standby). Required when mode = \"cluster\". Typically in a different AZ than instance A for cross-AZ HA."
  type = object({
    ami_id    = string
    subnet_id = string
  })
  default = null

  validation {
    # instance_b must be provided when mode = "cluster"
    condition     = var.mode != "cluster" || var.instance_b != null
    error_message = "instance_b is required when mode = \"cluster\"."
  }
}


# =============================================================================
# Optional Variables (sensible defaults matching agent defaults)
# =============================================================================

# --- Instance sizing ---

variable "instance_type" {
  description = "Default EC2 instance type for both nodes. ARM64 Graviton (t4g family) recommended."
  type        = string
  default     = "t4g.micro"
}

variable "instance_a_type" {
  description = "Override instance type for A only. Falls back to instance_type if null."
  type        = string
  default     = null
}

variable "instance_b_type" {
  description = "Override instance type for B only. Falls back to instance_type. Only relevant in cluster mode."
  type        = string
  default     = null
}

# --- IAM ---

variable "iam_instance_profile_name" {
  description = "Name of an existing IAM instance profile. When provided, the module skips creating IAM resources (role, policy, profile) and uses this instead. Useful when IAM is managed by a separate team/pipeline."
  type        = string
  default     = null
}

# --- SSH ---

variable "key_name" {
  description = "SSH key pair name. Omit (null) to disable SSH key-based access."
  type        = string
  default     = null
}

# --- Networking / Discovery ---

variable "group_tag_key" {
  description = "EC2 tag key for group membership (peer discovery). Only used in cluster mode. Matches discovery.DefaultGroupTagKey — agent/discovery/discovery.go:34"
  type        = string
  default     = "zeronat:group"
}

variable "vpc_cidr" {
  description = "If set, SG allows inbound from this CIDR for metrics, web UI, and SSH. Omit to restrict access to security group members only."
  type        = string
  default     = null
}

variable "control_port" {
  description = "TCP port for peer control plane. Only used in cluster mode. Matches discovery.DefaultControlPort — agent/discovery/discovery.go:31"
  type        = number
  default     = 7946

  validation {
    condition     = var.control_port >= 1 && var.control_port <= 65535
    error_message = "control_port must be between 1 and 65535."
  }
}

# --- Agent configuration ---

variable "metrics_addr" {
  description = "Prometheus metrics endpoint address (host:port or :port)."
  type        = string
  default     = ":9100"
}

variable "web_addr" {
  description = "Web UI endpoint address (host:port or :port). Agent default is 127.0.0.1:8080 (localhost only). Set to 0.0.0.0:8080 to allow access from the VPC."
  type        = string
  default     = null
}

variable "heartbeat_interval" {
  description = "Agent heartbeat interval (e.g. \"2s\"). Only set in user-data if non-null. Agent default: 1s. Cluster mode only."
  type        = string
  default     = null
}

variable "dead_threshold" {
  description = "Missed heartbeats before declaring peer dead. Only set in user-data if non-null. Agent default: 3. Cluster mode only."
  type        = number
  default     = null
}

variable "peer_scan_interval" {
  description = "How often to re-scan for peers (e.g. \"30s\"). Only set in user-data if non-null. Agent default: 60s. Cluster mode only. Matches discovery.DefaultPeerScanInterval — agent/discovery/discovery.go:37"
  type        = string
  default     = null
}

# --- Security Group extras ---

variable "additional_security_group_rules" {
  description = "Additional security group rules to attach to the ZeroNAT SG. Each rule must specify type (ingress/egress), protocol, ports, and either cidr_blocks or source_security_group_id."
  type = list(object({
    type                     = string # "ingress" or "egress"
    protocol                 = string # "tcp", "udp", "icmp", "-1", etc.
    from_port                = number
    to_port                  = number
    cidr_blocks              = optional(list(string), null)
    source_security_group_id = optional(string, null)
    description              = optional(string, "")
  }))
  default = []

  validation {
    condition = alltrue([
      for r in var.additional_security_group_rules :
      (r.cidr_blocks == null || r.source_security_group_id == null) &&
      contains(["ingress", "egress"], r.type)
    ])
    error_message = "Each additional_security_group_rules entry must set either cidr_blocks or source_security_group_id (not both), and type must be \"ingress\" or \"egress\"."
  }
}

# --- Elastic IP ---

variable "eip_allocation_id" {
  description = <<-EOT
    Existing EIP allocation ID for consistent public egress IP. The agent
    reassociates this EIP during failover so the cluster always egresses
    from the same public address. When null (default), the module creates
    a new EIP. When set to "none", no EIP is created or managed.
  EOT
  type    = string
  default = null
}

# --- Tagging ---

variable "tags" {
  description = "Additional tags merged onto all taggable resources."
  type        = map(string)
  default     = {}
}

# --- Log shipping ---

variable "cloudwatch_log_group" {
  description = <<-EOT
    Base name for CloudWatch Log Groups. When set, the module creates a log group
    for the agent, adds the required IAM permissions to the instance role, and
    renders a CloudWatch agent config via user-data.
    When null (default), no log groups are created, no IAM permissions are
    added, and the pre-installed CloudWatch agent sits dormant. Zero cost.
    Example: "zeronat" creates /zeronat/agent.
  EOT
  type        = string
  default     = null
}

variable "cloudwatch_log_retention_days" {
  description = "Retention period in days for CloudWatch Log Groups created by this module. Only used when cloudwatch_log_group is set."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.cloudwatch_log_retention_days)
    error_message = "cloudwatch_log_retention_days must be a valid CloudWatch retention value."
  }
}
