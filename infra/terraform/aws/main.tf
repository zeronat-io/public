# =============================================================================
# ZeroNAT Terraform Module — Main Resources
# =============================================================================
#
# This file creates the core infrastructure:
#   1. Security group — egress all, conditional ingress rules by mode
#   2. EC2 instances — A (always), B (cluster mode only)
#   3. Route table tags — group tag for agent route discovery (both modes)
#
# Resource flow:
#
#   aws_security_group.zeronat
#     │
#     ├─► aws_instance.a  (always)  ──► TAKEOVER_ON_BOOT=true → agent creates/replaces routes when ready
#     │     └─ source_dest_check = false
#     │     └─ iam_instance_profile
#     │     └─ user_data_a (includes ZERONAT_TAKEOVER_ON_BOOT=true)
#     │
#     └─► aws_instance.b  (cluster) ──► failover target (agent manages at runtime)
#           └─ source_dest_check = false
#           └─ user_data_b (no TAKEOVER_ON_BOOT — avoids race with A)
#
# =============================================================================


# =============================================================================
# Locals — helper expressions
# =============================================================================

locals {
  # Whether we're in cluster mode (used throughout for readability)
  is_cluster = var.mode == "cluster"

  # Extract port number from an addr string like ":9100" or "0.0.0.0:9100".
  # split(":") gives ["", "9100"] or ["0.0.0.0", "9100"] — we always want the last element.
  metrics_port = tonumber(split(":", var.metrics_addr)[length(split(":", var.metrics_addr)) - 1])
  # web_addr defaults to null (agent uses 127.0.0.1:8080). Extract port when set, otherwise use 8080.
  web_port     = var.web_addr != null ? tonumber(split(":", var.web_addr)[length(split(":", var.web_addr)) - 1]) : 8080
}


# =============================================================================
# Security Group
# =============================================================================
#
# Rule matrix:
#   Rule                  | Proto | Port             | Source     | Condition
#   ─────────────────────-+───────+──────────────────+───────────-+──────────────────────────
#   Egress all            | -1    | all              | 0.0.0.0/0 | Always
#   NAT traffic           | -1    | all              | vpc_cidr  | vpc_cidr != null
#   Peer control          | TCP   | var.control_port | Self      | mode == "cluster"
#   Prometheus metrics    | TCP   | metrics_port     | vpc_cidr  | vpc_cidr != null
#   Web UI                | TCP   | web_port         | vpc_cidr  | vpc_cidr != null
#   SSH                   | TCP   | 22               | vpc_cidr  | vpc_cidr != null && key_name != null
# =============================================================================

resource "aws_security_group" "zeronat" {
  name_prefix = "${var.name}-zeronat-" # name_prefix (not name) avoids collision when multiple modules share a VPC
  description = "ZeroNAT NAT instance security group"
  vpc_id      = var.vpc_id

  tags = merge({ Name = "${var.name}-zeronat" }, var.tags)

  lifecycle {
    create_before_destroy = true # Required with name_prefix to avoid downtime on replacement
  }
}

# --- Egress: allow all outbound (NAT instances must reach the internet) ---

resource "aws_security_group_rule" "egress_all" {
  security_group_id = aws_security_group.zeronat.id
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound traffic"
}

# --- NAT traffic: allow all inbound from VPC ---
# This is the core NAT rule — private subnet instances send their outbound
# traffic TO the ZeroNAT ENI (via 0.0.0.0/0 route). Without this rule, the
# SG would block that traffic before it reaches the NAT instance.
resource "aws_security_group_rule" "nat_ingress" {
  count = var.vpc_cidr != null ? 1 : 0

  security_group_id = aws_security_group.zeronat.id
  type              = "ingress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = [var.vpc_cidr]
  description       = "NAT traffic from VPC"
}

# --- Cluster-only: peer control plane (TCP) ---
# Used for TCP handshake + heartbeat between peers.
# Matches discovery.DefaultControlPort — agent/discovery/discovery.go:31
resource "aws_security_group_rule" "peer_control" {
  count = local.is_cluster ? 1 : 0 # Only in cluster mode — no peers in single mode

  security_group_id        = aws_security_group.zeronat.id
  type                     = "ingress"
  protocol                 = "tcp"
  from_port                = var.control_port
  to_port                  = var.control_port
  source_security_group_id = aws_security_group.zeronat.id # Self-referencing: only peers in this SG
  description              = "Peer control plane (TCP ${var.control_port})"
}

# --- Conditional: Prometheus metrics (TCP) ---
# Allows scraping from within the VPC when vpc_cidr is provided.
resource "aws_security_group_rule" "metrics" {
  count = var.vpc_cidr != null ? 1 : 0 # Only when vpc_cidr is provided

  security_group_id = aws_security_group.zeronat.id
  type              = "ingress"
  protocol          = "tcp"
  from_port         = local.metrics_port
  to_port           = local.metrics_port
  cidr_blocks       = [var.vpc_cidr]
  description       = "Prometheus metrics (TCP ${local.metrics_port})"
}

# --- Conditional: Web UI (TCP) ---
# Allows access to the web dashboard from within the VPC.
resource "aws_security_group_rule" "web_ui" {
  count = var.vpc_cidr != null ? 1 : 0 # Only when vpc_cidr is provided

  security_group_id = aws_security_group.zeronat.id
  type              = "ingress"
  protocol          = "tcp"
  from_port         = local.web_port
  to_port           = local.web_port
  cidr_blocks       = [var.vpc_cidr]
  description       = "Web UI (TCP ${local.web_port})"
}

# --- Conditional: SSH (TCP 22) ---
# Only created when BOTH vpc_cidr and key_name are set — no point opening SSH
# if there's no key pair to authenticate with.
resource "aws_security_group_rule" "ssh" {
  count = var.vpc_cidr != null && var.key_name != null ? 1 : 0

  security_group_id = aws_security_group.zeronat.id
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_blocks       = [var.vpc_cidr]
  description       = "SSH (TCP 22)"
}

# --- User-defined additional rules ---
# Allows callers to add custom ingress/egress rules without managing a separate
# SG. Each rule can use either cidr_blocks or source_security_group_id.
resource "aws_security_group_rule" "additional" {
  for_each = { for idx, rule in var.additional_security_group_rules : idx => rule }

  security_group_id        = aws_security_group.zeronat.id
  type                     = each.value.type
  protocol                 = each.value.protocol
  from_port                = each.value.from_port
  to_port                  = each.value.to_port
  cidr_blocks              = each.value.cidr_blocks
  source_security_group_id = each.value.source_security_group_id
  description              = each.value.description
}


# =============================================================================
# EC2 Instances
# =============================================================================
#
# Two discrete resources (not for_each) because they have different semantics:
#   - Instance A: always created, initial route target, "active" in cluster mode
#   - Instance B: cluster mode only, standby, failover target
#
# Both instances:
#   - source_dest_check = false (required for NAT functionality)
#   - Share the same IAM profile, security group, and user-data
#   - In cluster mode, tagged with the group tag for peer discovery
# =============================================================================

# --- Instance A (always created) ---
resource "aws_instance" "a" {
  ami                    = var.instance_a.ami_id
  instance_type          = coalesce(var.instance_a_type, var.instance_type) # Per-instance override, fallback to shared default
  subnet_id              = var.instance_a.subnet_id
  source_dest_check      = false                       # Required: NAT instances forward traffic not destined for their own IP
  iam_instance_profile   = local.instance_profile_name # Resolved in iam.tf: caller-provided or module-created
  vpc_security_group_ids = [aws_security_group.zeronat.id]
  key_name               = var.key_name
  user_data              = local.userdata_a # Includes ZERONAT_TAKEOVER_ON_BOOT=true (see userdata.tf)
  user_data_replace_on_change = true             # Re-creates the instance when user-data changes; in-place updates do not re-run user-data

  tags = merge(
    { Name = "${var.name}-a" },
    # Group tag is always applied — the agent uses it to discover managed route
    # tables (both modes) and for peer discovery (cluster mode).
    { (var.group_tag_key) = var.name },
    var.tags,
  )
}

# --- Instance B (cluster mode only — standby node) ---
resource "aws_instance" "b" {
  count = local.is_cluster ? 1 : 0 # Only created in cluster mode

  ami                    = var.instance_b.ami_id
  instance_type          = coalesce(var.instance_b_type, var.instance_type) # Per-instance override, fallback to shared default
  subnet_id              = var.instance_b.subnet_id
  source_dest_check      = false                       # Required: NAT instances forward traffic not destined for their own IP
  iam_instance_profile   = local.instance_profile_name # Resolved in iam.tf: caller-provided or module-created
  vpc_security_group_ids = [aws_security_group.zeronat.id]
  key_name               = var.key_name
  user_data              = local.userdata_b # No TAKEOVER_ON_BOOT — avoids race with instance A during initial deploy
  user_data_replace_on_change = true             # Re-creates the instance when user-data changes; in-place updates do not re-run user-data

  tags = merge(
    { Name = "${var.name}-b" },
    { (var.group_tag_key) = var.name }, # Group tag for peer discovery
    var.tags,
  )
}


# =============================================================================
# Route Table Tags (both modes)
# =============================================================================
#
# Tags each managed route table with the group tag so the agent can discover
# which route tables it manages. Used in both modes:
#   - Single: agent discovers route tables at boot to create/replace routes
#   - Cluster: also used during failover (see agent/failover/failover.go)
# =============================================================================

resource "aws_ec2_tag" "route_table" {
  for_each = { for i, id in var.route_table_ids : tostring(i) => id }

  resource_id = each.value
  key         = var.group_tag_key
  value       = var.name
}

# --- Active route table tags ---
# Tags route tables that the agent should actively claim (route takeover).
# When active_route_table_ids is null (default), all route tables are active.
# When set, only the specified subset gets the active tag — enabling gradual
# migration from AWS NAT Gateway one subnet at a time.
resource "aws_ec2_tag" "rt_active" {
  for_each = {
    for i, id in coalesce(var.active_route_table_ids, var.route_table_ids) :
    tostring(i) => id
  }

  resource_id = each.value
  key         = "${var.group_tag_key}:active"
  value       = "true"
}

# =============================================================================
# Elastic IP (shared public egress address)
# =============================================================================
#
# When eip_allocation_id is null, the module creates a new EIP.
# When eip_allocation_id is a real allocation ID, the module uses it.
# When eip_allocation_id is "none", no EIP resources are created.
#
# The EIP is initially associated with instance A. During failover the
# agent calls AssociateAddress to move it to the surviving node.
# =============================================================================

locals {
  manage_eip = var.eip_allocation_id != "none"
  eip_alloc  = local.manage_eip ? coalesce(var.eip_allocation_id, try(aws_eip.nat[0].id, null)) : null
}

resource "aws_eip" "nat" {
  count  = var.eip_allocation_id == null ? 1 : 0
  domain = "vpc"

  tags = merge({ Name = "${var.name}-nat-eip" }, var.tags)
}

resource "aws_eip_association" "nat" {
  count         = local.manage_eip ? 1 : 0
  allocation_id = local.eip_alloc

  network_interface_id = aws_instance.a.primary_network_interface_id
}


# =============================================================================
# Routes — managed by the agent, NOT by Terraform
# =============================================================================
#
# The 0.0.0.0/0 route is NOT created here. Instead, instance A boots with
# ZERONAT_TAKEOVER_ON_BOOT=true in its user-data. The agent creates or replaces
# the default route only after all services (nftables, health
# checks) are fully initialized — ensuring zero-downtime deployments.
#
# Only instance A gets TAKEOVER_ON_BOOT=true to avoid a race condition when
# both nodes start simultaneously in cluster mode.
#
# If the route tables have no existing 0.0.0.0/0 route, the agent creates one.
# If a route already exists (e.g. pointing to an IGW or old NAT GW), the agent
# replaces it. See agent/failover/failover.go:161.
# =============================================================================
