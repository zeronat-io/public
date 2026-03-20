# =============================================================================
# Example: ZeroNAT HA Cluster Per Availability Zone
# =============================================================================
#
# Topology:
#
#   ┌──────────────────────────────────────────────────────────────────────┐
#   │ VPC 10.0.0.0/16                                                     │
#   │                                                                      │
#   │  AZ-a                                    AZ-b                        │
#   │  ┌──────────────────────┐                ┌──────────────────────┐    │
#   │  │ Public 10.0.1.0/24   │                │ Public 10.0.2.0/24   │    │
#   │  │                      │                │                      │    │
#   │  │  ┌────────┐ conntrackd ┌────────┐    │  ┌────────┐ conntrackd ┌────────┐  │
#   │  │  │ NAT-a1 │◄─────────►│ NAT-a2 │    │  │ NAT-b1 │◄─────────►│ NAT-b2 │  │
#   │  │  │ active │           │standby │    │  │ active │           │standby │  │
#   │  │  └───┬────┘           └────────┘    │  └───┬────┘           └────────┘  │
#   │  └──────┼────────────────────────────────┘──────┼────────────────────────────┘
#   │         │ 0.0.0.0/0                             │ 0.0.0.0/0
#   │  ┌──────┼───────────────┐                ┌──────┼───────────────┐    │
#   │  │ Private 10.0.10.0/24 │                │ Private 10.0.20.0/24 │    │
#   │  │  RT-a                │                │  RT-b                │    │
#   │  │  ┌──────────────┐   │                │  ┌──────────────┐   │    │
#   │  │  │ test instance │   │                │  │ test instance │   │    │
#   │  │  └──────────────┘   │                │  └──────────────┘   │    │
#   │  └──────────────────────┘                └──────────────────────┘    │
#   └──────────────────────────────────────────────────────────────────────┘
#                    │                                     │
#                    └──────────────┬───────────────────────┘
#                                ┌──┴──┐
#                                │ IGW │
#                                └─────┘
#
# - Two independent HA clusters, one per AZ.
# - Each cluster has two nodes in the same public subnet (same AZ).
# - Each cluster controls only its AZ's private route table.
# - Provides both HA (within AZ) and AZ isolation (no cross-AZ NAT traffic).
# - Most resilient topology: an AZ failure only affects that AZ's NAT.
#
# Note: Both nodes of each cluster are in the same subnet for this example.
# In production you might place them in separate subnets for fault isolation.
# =============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}


# =============================================================================
# Variables
# =============================================================================

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-west-2"
}

variable "zeronat_ami_id" {
  description = "AMI ID for ZeroNAT instances (pre-baked with the agent)."
  type        = string
}

variable "test_ami_id" {
  description = "AMI ID for test instances (e.g. Amazon Linux 2023 ARM64)."
  type        = string
}

variable "key_name" {
  description = "SSH key pair name. Omit to disable SSH access."
  type        = string
  default     = null
}


# =============================================================================
# Data Sources
# =============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}


# =============================================================================
# VPC + Internet Gateway
# =============================================================================

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "zeronat-cluster-per-az" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "zeronat-cluster-per-az" }
}


# =============================================================================
# Subnets
# =============================================================================

# --- Public subnets (ZeroNAT clusters live here) ---

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "zeronat-cluster-per-az-public-a" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = { Name = "zeronat-cluster-per-az-public-b" }
}

# --- Private subnets (test instances live here) ---

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = { Name = "zeronat-cluster-per-az-private-a" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.20.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = { Name = "zeronat-cluster-per-az-private-b" }
}


# =============================================================================
# Route Tables
# =============================================================================

# --- Public route table: 0.0.0.0/0 → IGW ---

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "zeronat-cluster-per-az-public" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# --- Private route tables: one per AZ, each managed by its own cluster ---

resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "zeronat-cluster-per-az-private-a" }
}

resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "zeronat-cluster-per-az-private-b" }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private_b.id
}


# =============================================================================
# ZeroNAT Modules — One HA Cluster Per AZ
# =============================================================================

# --- Cluster A: both nodes in public-a, controls private RT-a ---
# Both nodes are in the same subnet (same AZ). The cluster provides HA within
# this AZ — if the active node fails, the standby takes over and re-points
# the route table to its own ENI.

module "nat_a" {
  source = "../../"

  name     = "cluster-az-a"
  mode     = "cluster"
  vpc_id   = aws_vpc.this.id
  vpc_cidr = aws_vpc.this.cidr_block
  key_name = var.key_name
  web_addr = "0.0.0.0:8080" # Allow web UI access from within the VPC (agent defaults to localhost only)

  instance_a = {
    ami_id    = var.zeronat_ami_id
    subnet_id = aws_subnet.public_a.id
  }

  instance_b = {
    ami_id    = var.zeronat_ami_id
    subnet_id = aws_subnet.public_a.id # Same subnet — both nodes in AZ-a
  }

  route_table_ids = [aws_route_table.private_a.id]
}

# --- Cluster B: both nodes in public-b, controls private RT-b ---

module "nat_b" {
  source = "../../"

  name     = "cluster-az-b"
  mode     = "cluster"
  vpc_id   = aws_vpc.this.id
  vpc_cidr = aws_vpc.this.cidr_block
  key_name = var.key_name
  web_addr = "0.0.0.0:8080" # Allow web UI access from within the VPC (agent defaults to localhost only)

  instance_a = {
    ami_id    = var.zeronat_ami_id
    subnet_id = aws_subnet.public_b.id
  }

  instance_b = {
    ami_id    = var.zeronat_ami_id
    subnet_id = aws_subnet.public_b.id # Same subnet — both nodes in AZ-b
  }

  route_table_ids = [aws_route_table.private_b.id]
}


# =============================================================================
# Test Instances (one per private subnet)
# =============================================================================

resource "aws_instance" "test_a" {
  ami                    = var.test_ami_id
  instance_type          = "t4g.nano"
  subnet_id              = aws_subnet.private_a.id
  vpc_security_group_ids = [aws_security_group.test.id]
  key_name               = var.key_name

  tags = { Name = "zeronat-cluster-per-az-test-a" }
}

resource "aws_instance" "test_b" {
  ami                    = var.test_ami_id
  instance_type          = "t4g.nano"
  subnet_id              = aws_subnet.private_b.id
  vpc_security_group_ids = [aws_security_group.test.id]
  key_name               = var.key_name

  tags = { Name = "zeronat-cluster-per-az-test-b" }
}

# --- Test instance security group ---

resource "aws_security_group" "test" {
  name        = "zeronat-cluster-per-az-test"
  description = "Test instances - egress all, SSH from VPC"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "zeronat-cluster-per-az-test" }
}

resource "aws_security_group_rule" "test_egress" {
  security_group_id = aws_security_group.test.id
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "test_ssh" {
  count = var.key_name != null ? 1 : 0

  security_group_id = aws_security_group.test.id
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_blocks       = [aws_vpc.this.cidr_block]
}


# =============================================================================
# Outputs
# =============================================================================

output "cluster_a_instance_a_id" {
  value = module.nat_a.instance_a_id
}

output "cluster_a_instance_b_id" {
  value = module.nat_a.instance_b_id
}

output "cluster_b_instance_a_id" {
  value = module.nat_b.instance_a_id
}

output "cluster_b_instance_b_id" {
  value = module.nat_b.instance_b_id
}

output "cluster_a_instance_a_private_ip" {
  value = module.nat_a.instance_a_private_ip
}

output "cluster_a_instance_b_private_ip" {
  value = module.nat_a.instance_b_private_ip
}

output "cluster_b_instance_a_private_ip" {
  value = module.nat_b.instance_a_private_ip
}

output "cluster_b_instance_b_private_ip" {
  value = module.nat_b.instance_b_private_ip
}

output "test_a_private_ip" {
  value = aws_instance.test_a.private_ip
}

output "test_b_private_ip" {
  value = aws_instance.test_b.private_ip
}
