# =============================================================================
# Example: Single ZeroNAT Instance (Simplest Setup)
# =============================================================================
#
# Topology:
#
#   ┌──────────────────────────────────────────────────────────┐
#   │ VPC 10.0.0.0/16                                         │
#   │                                                          │
#   │   ┌─────────────────────┐                                │
#   │   │ Public Subnet A      │                                │
#   │   │ 10.0.1.0/24          │                                │
#   │   │                      │                                │
#   │   │  ┌────────────────┐  │                                │
#   │   │  │ ZeroNAT (single)│  │                                │
#   │   │  └───────┬────────┘  │                                │
#   │   └──────────┼───────────┘                                │
#   │              │ 0.0.0.0/0                                  │
#   │   ┌──────────┼───────────┐   ┌──────────────────────────┐│
#   │   │ Private Subnet A     │   │ Private Subnet B          ││
#   │   │ 10.0.10.0/24         │   │ 10.0.20.0/24             ││
#   │   │                      │   │                           ││
#   │   │  ┌──────────────┐   │   │  ┌──────────────┐        ││
#   │   │  │ test instance │   │   │  │ test instance │        ││
#   │   │  └──────────────┘   │   │  └──────────────┘        ││
#   │   └──────────────────────┘   └──────────────────────────┘│
#   └──────────────────────────────────────────────────────────┘
#              │
#           ┌──┴──┐
#           │ IGW │
#           └─────┘
#
# - One public subnet, two private subnets, one shared private route table.
# - ZeroNAT in single mode — no HA, no peer discovery.
# - Both private subnets route 0.0.0.0/0 through the ZeroNAT ENI.
# - Test instances in private subnets for connectivity verification.
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

  tags = { Name = "zeronat-single-basic" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "zeronat-single-basic" }
}


# =============================================================================
# Subnets
# =============================================================================

# --- Public subnet (ZeroNAT lives here) ---

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "zeronat-single-basic-public-a" }
}

# --- Private subnets (test instances live here) ---

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = { Name = "zeronat-single-basic-private-a" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.20.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = { Name = "zeronat-single-basic-private-b" }
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

  tags = { Name = "zeronat-single-basic-public" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

# --- Private route table: 0.0.0.0/0 → ZeroNAT ENI (managed by the module) ---

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  # The 0.0.0.0/0 route is created by the ZeroNAT agent at boot (TAKEOVER_ON_BOOT).
  tags = { Name = "zeronat-single-basic-private" }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}


# =============================================================================
# ZeroNAT Module — Single Mode
# =============================================================================

module "nat" {
  source = "../../"

  name     = "single-basic"
  vpc_id   = aws_vpc.this.id
  vpc_cidr = aws_vpc.this.cidr_block
  key_name = var.key_name
  web_addr = "0.0.0.0:8080" # Allow web UI access from within the VPC (agent defaults to localhost only)

  instance_a = {
    ami_id    = var.zeronat_ami_id
    subnet_id = aws_subnet.public_a.id
  }

  route_table_ids = [aws_route_table.private.id]
}


# =============================================================================
# Test Instances (private subnets — verify traffic routes through ZeroNAT)
# =============================================================================

resource "aws_instance" "test_a" {
  ami                    = var.test_ami_id
  instance_type          = "t4g.nano"
  subnet_id              = aws_subnet.private_a.id
  vpc_security_group_ids = [aws_security_group.test.id]
  key_name               = var.key_name

  tags = { Name = "zeronat-single-basic-test-a" }
}

resource "aws_instance" "test_b" {
  ami                    = var.test_ami_id
  instance_type          = "t4g.nano"
  subnet_id              = aws_subnet.private_b.id
  vpc_security_group_ids = [aws_security_group.test.id]
  key_name               = var.key_name

  tags = { Name = "zeronat-single-basic-test-b" }
}

# --- Test instance security group: allow all egress, SSH from VPC ---

resource "aws_security_group" "test" {
  name        = "zeronat-single-basic-test"
  description = "Test instances - egress all, SSH from VPC"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "zeronat-single-basic-test" }
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

output "nat_instance_a_id" {
  value = module.nat.instance_a_id
}

output "nat_instance_a_private_ip" {
  value = module.nat.instance_a_private_ip
}

output "test_instance_a_private_ip" {
  value = aws_instance.test_a.private_ip
}

output "test_instance_b_private_ip" {
  value = aws_instance.test_b.private_ip
}
