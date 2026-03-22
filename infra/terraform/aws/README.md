# ZeroNAT AWS Terraform Module

Deploys a ZeroNAT NAT appliance on AWS. Supports two modes:

- **single** — one NAT instance, no failover
- **cluster** — two instances across AZs with sub-second failover

The module creates EC2 instances, a security group, IAM role and instance profile, and tags the route tables so the agent can discover and manage them. Routes are set by the agent at boot — not by Terraform — so failover works without any Terraform involvement.

---

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.5 |
| hashicorp/aws | >= 5.0 |

---

## Usage

### Cluster (HA, recommended for production)

```hcl
module "zeronat" {
  source = "path/to/infra/terraform/aws"

  name   = "prod-nat"
  mode   = "cluster"
  vpc_id = aws_vpc.this.id

  instance_a = {
    ami_id    = var.zeronat_ami_id
    subnet_id = aws_subnet.public_a.id
  }

  instance_b = {
    ami_id    = var.zeronat_ami_id
    subnet_id = aws_subnet.public_b.id
  }

  route_table_ids = [
    aws_route_table.private_a.id,
    aws_route_table.private_b.id,
  ]

  instance_type = "t4g.small"
  key_name      = var.key_name
  vpc_cidr      = "10.0.0.0/16"
}
```

Two ZeroNAT nodes start up, discover each other via EC2 tags, elect an active node, and set the `0.0.0.0/0` routes. If the active node fails its health checks, the standby takes over by re-pointing all route tables to its own ENI and claiming the shared Elastic IP.

### Single instance

```hcl
module "zeronat" {
  source = "path/to/infra/terraform/aws"

  name   = "dev-nat"
  mode   = "single"
  vpc_id = aws_vpc.this.id

  instance_a = {
    ami_id    = var.zeronat_ami_id
    subnet_id = aws_subnet.public.id
  }

  route_table_ids = [aws_route_table.private.id]

  instance_type = "t4g.micro"
}
```

No peer discovery, no failover. Suitable for development or non-critical environments where cost matters more than availability.

---

## Migrating from AWS Managed NAT Gateway

Use `active_route_table_ids` to cut over one subnet at a time without touching the rest:

```hcl
module "zeronat" {
  source = "path/to/infra/terraform/aws"

  name   = "prod-nat"
  mode   = "cluster"
  vpc_id = aws_vpc.this.id

  instance_a = { ami_id = var.zeronat_ami_id, subnet_id = aws_subnet.public_a.id }
  instance_b = { ami_id = var.zeronat_ami_id, subnet_id = aws_subnet.public_b.id }

  # All private route tables are tagged for discovery and shown in the dashboard,
  # but only the first one will have its 0.0.0.0/0 route replaced at boot.
  route_table_ids = [
    aws_route_table.private_a.id,
    aws_route_table.private_b.id,
    aws_route_table.private_c.id,
  ]

  active_route_table_ids = [
    aws_route_table.private_a.id,  # migrated; ZeroNAT manages this route
    # private_b and private_c still route through the AWS NAT Gateway
  ]
}
```

Verify egress from subnet A works, then add the remaining route tables to `active_route_table_ids` and re-apply. The agent claims the new tables on the next re-scan (`peer_scan_interval`, default 60 s) without a restart.

---

## IAM

By default the module creates an IAM role with least-privilege permissions:

| Permission | Purpose |
|---|---|
| `ec2:DescribeInstances` | Tag-based peer discovery |
| `ec2:DescribeRouteTables` | Discover managed route tables |
| `ec2:ReplaceRoute` | Redirect route table entry to own ENI on failover |
| `ec2:CreateRoute` | Create the initial 0.0.0.0/0 route on boot |
| `cloudwatch:GetMetricData` | Read `CPUCreditBalance` for T-series instances (optional) |

If your organization manages IAM separately, pass the existing profile name and the module skips all IAM resource creation:

```hcl
iam_instance_profile_name = aws_iam_instance_profile.existing.name
```

---

## Inputs

### Required

| Name | Description | Type |
|---|---|---|
| `name` | Resource name prefix. Also used as the group tag value for peer discovery. | `string` |
| `vpc_id` | VPC to deploy into. | `string` |
| `instance_a` | Instance A config: `{ ami_id, subnet_id }`. The initial active node. | `object` |
| `route_table_ids` | Private-subnet route tables to manage. Must contain at least one entry. | `list(string)` |

### Mode

| Name | Description | Type | Default |
|---|---|---|---|
| `mode` | `"single"` or `"cluster"`. | `string` | `"single"` |

### Cluster only

| Name | Description | Type | Default |
|---|---|---|---|
| `instance_b` | Instance B config: `{ ami_id, subnet_id }`. Required in cluster mode. | `object` | `null` |

### Optional

| Name | Description | Type | Default |
|---|---|---|---|
| `active_route_table_ids` | Subset of `route_table_ids` to take over at boot. Defaults to all of `route_table_ids`. Use for gradual cut-over from AWS NAT GW. | `list(string)` | `null` |
| `instance_type` | Default EC2 instance type for both nodes. | `string` | `"t4g.micro"` |
| `instance_a_type` | Override instance type for A only. | `string` | `null` |
| `instance_b_type` | Override instance type for B only. | `string` | `null` |
| `iam_instance_profile_name` | Existing IAM instance profile name. Skips IAM resource creation when set. | `string` | `null` |
| `key_name` | SSH key pair name. Omit to disable SSH access. | `string` | `null` |
| `group_tag_key` | EC2 tag key for peer discovery group membership. | `string` | `"zeronat:group"` |
| `vpc_cidr` | Allow inbound from this CIDR for metrics, Web UI, and SSH. Omit to restrict to SG members only. | `string` | `null` |
| `control_port` | TCP port for peer control plane. | `number` | `7946` |
| `metrics_addr` | Prometheus metrics endpoint address. | `string` | `":9100"` |
| `web_addr` | Web UI address. Set to `"0.0.0.0:8080"` to allow VPC access. | `string` | `null` |
| `heartbeat_interval` | Agent heartbeat interval (e.g. `"2s"`). Cluster mode only. | `string` | `null` |
| `dead_threshold` | Missed heartbeats before declaring peer dead. Cluster mode only. | `number` | `null` |
| `peer_scan_interval` | How often to re-scan for peers (e.g. `"30s"`). Cluster mode only. | `string` | `null` |
| `additional_security_group_rules` | Extra SG rules to attach to the ZeroNAT security group. | `list(object)` | `[]` |
| `tags` | Additional tags merged onto all taggable resources. | `map(string)` | `{}` |
| `cloudwatch_log_group` | Base name for CloudWatch Log Groups (e.g. `"zeronat"`). Creates `/name/agent`. Null = no log groups, no cost. | `string` | `null` |
| `cloudwatch_log_retention_days` | Retention days for CloudWatch Log Groups. Only used when `cloudwatch_log_group` is set. | `number` | `30` |

---

## Outputs

| Name | Description |
|---|---|
| `instance_a_id` | Instance A ID. |
| `instance_b_id` | Instance B ID. Null in single mode. |
| `instance_a_private_ip` | Instance A private IP. |
| `instance_b_private_ip` | Instance B private IP. Null in single mode. |
| `instance_a_eni_id` | Instance A primary ENI ID. Route tables point to this ENI. |
| `instance_b_eni_id` | Instance B primary ENI ID. Null in single mode. |
| `security_group_id` | Security group ID. Use to attach additional rules from other modules. |
| `iam_role_arn` | IAM role ARN. Null when using an external instance profile. |
| `iam_role_name` | IAM role name. Null when using an external instance profile. |

---

## Examples

| Example | Description |
|---|---|
| [`examples/cluster-basic`](examples/cluster-basic/) | HA pair across two AZs — the typical production setup |
| [`examples/cluster-per-az`](examples/cluster-per-az/) | HA pair with per-AZ private route tables |
| [`examples/single-basic`](examples/single-basic/) | Single instance with one shared route table |
| [`examples/single-per-az`](examples/single-per-az/) | Single instance serving multiple per-AZ route tables |

Each example creates a complete VPC (IGW, public and private subnets, route tables) and includes test instances in the private subnets for verifying egress.
