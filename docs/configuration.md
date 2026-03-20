# Terraform Configuration Reference

All input variables for the ZeroNAT Terraform module
(`registry.terraform.io/zeronat-io/zeronat/aws`).

---

## Required variables

These have no defaults. You must provide them.

### `name`
Resource name prefix. Also used as the group tag value for peer discovery in
cluster mode. Must be non-empty.

```hcl
name = "prod"
```

### `vpc_id`
The VPC to deploy into. Used for security group creation.

```hcl
vpc_id = "vpc-0abc1234def56789a"
```

### `instance_a`
Configuration for the primary instance (always created). In `cluster` mode this
is the initial active node.

```hcl
instance_a = {
  ami_id    = "ami-XXXXXXXXXXXXXXXXX"   # ZeroNAT AMI from Marketplace
  subnet_id = "subnet-0aaaaaaaaaaaaaaaa" # must be a public subnet
}
```

### `route_table_ids`
List of private-subnet route table IDs to manage. The agent updates the
`0.0.0.0/0` route in each of these tables. At least one is required.

```hcl
route_table_ids = [
  "rtb-0111111111111111",
  "rtb-0222222222222222",
]
```

---

## Mode selection

### `mode`
`"single"` for a standalone NAT instance; `"cluster"` for an HA pair with
conntrack sync and automatic failover.

Default: `"single"`

```hcl
mode = "cluster"
```

---

## Cluster-only variables

These are only relevant when `mode = "cluster"`.

### `instance_b`
Configuration for the standby instance. Required when `mode = "cluster"`.
Should be in a different AZ than `instance_a`.

```hcl
instance_b = {
  ami_id    = "ami-XXXXXXXXXXXXXXXXX"
  subnet_id = "subnet-0bbbbbbbbbbbbbbb" # public subnet, different AZ
}
```

---

## Optional variables

### Instance sizing

| Variable | Default | Description |
|---|---|---|
| `instance_type` | `"t4g.micro"` | EC2 instance type for both nodes. ARM64 Graviton (t4g family) required. |
| `instance_a_type` | `null` | Override instance type for node A only. Falls back to `instance_type` if null. |
| `instance_b_type` | `null` | Override instance type for node B only. Falls back to `instance_type` if null. |

### Route migration

### `active_route_table_ids`
Subset of `route_table_ids` that the agent actively manages (takes over at
boot). Defaults to all of `route_table_ids` when null.

Use this for gradual migration from AWS NAT Gateway: start with one route
table, verify traffic flows, then expand.

```hcl
active_route_table_ids = ["rtb-0111111111111111"]
```

Route tables in `route_table_ids` but not in `active_route_table_ids` are
tagged for discovery but the agent does not claim their routes.

Default: `null` (all route tables are active)

### IAM

| Variable | Default | Description |
|---|---|---|
| `iam_instance_profile_name` | `null` | Name of an existing IAM instance profile. When set, the module skips creating IAM resources. Use this when IAM is managed by a separate team or pipeline. |

### SSH

| Variable | Default | Description |
|---|---|---|
| `key_name` | `null` | SSH key pair name. Omit to disable SSH key-based access. |

### Networking

| Variable | Default | Description |
|---|---|---|
| `group_tag_key` | `"zeronat:group"` | EC2 tag key used for peer discovery. Only relevant in cluster mode. Both nodes must share a tag with this key and the same value (`name`). |
| `vpc_cidr` | `null` | If set, the security group allows inbound access from this CIDR for metrics (`:9100`), web UI (`:8080`), and SSH (`:22`). Omit to restrict to security group members only. |
| `control_port` | `7946` | TCP port for the peer control plane (heartbeat). Only used in cluster mode. |
| `conntrackd_port` | `3780` | UDP port for conntrackd state sync. Only used in cluster mode. |

### Agent behaviour

| Variable | Default | Description |
|---|---|---|
| `metrics_addr` | `":9100"` | Prometheus metrics listen address. |
| `web_addr` | `null` | Web UI listen address. Agent default is `127.0.0.1:8080` (localhost only). Set to `"0.0.0.0:8080"` to allow access from within the VPC. |
| `heartbeat_interval` | `null` (agent default: `1s`) | How often nodes exchange heartbeat messages. Only set in user-data if non-null. |
| `dead_threshold` | `null` (agent default: `3`) | Number of missed heartbeats before declaring peer dead and initiating failover. Only set in user-data if non-null. |
| `peer_scan_interval` | `null` (agent default: `60s`) | How often to re-scan for peers via EC2 tags. Only set in user-data if non-null. |

### Log shipping

| Variable | Default | Description |
|---|---|---|
| `cloudwatch_log_group` | `null` | Base name for CloudWatch Log Groups. When set, the module creates log groups for the agent and conntrackd, adds the required IAM permissions, and configures the pre-installed CloudWatch agent. Example: `"zeronat"` creates `/zeronat/agent` and `/zeronat/conntrackd`. |
| `cloudwatch_log_retention_days` | `30` | Retention period in days for log groups created by this module. Must be a valid CloudWatch retention value. Only used when `cloudwatch_log_group` is set. |

### Tagging

| Variable | Default | Description |
|---|---|---|
| `tags` | `{}` | Additional tags merged onto all taggable resources. |
| `additional_security_group_rules` | `[]` | Extra security group rules to attach to the ZeroNAT security group. Each rule specifies `type`, `protocol`, `from_port`, `to_port`, and either `cidr_blocks` or `source_security_group_id`. |

---

## Outputs

| Output | Description |
|---|---|
| `instance_ids` | Map of `{ a = "i-...", b = "i-..." }` (or just `{ a = "i-..." }` in single mode) |
| `instance_profile_arn` | ARN of the IAM instance profile (useful if you add extra policies) |
| `security_group_id` | ID of the ZeroNAT security group |

---

## Example: minimal cluster

```hcl
module "zeronat" {
  source  = "registry.terraform.io/zeronat-io/zeronat/aws"
  version = "~> 1.0"

  name            = "prod"
  vpc_id          = "vpc-0abc1234def56789a"
  mode            = "cluster"
  route_table_ids = ["rtb-0111111111111111", "rtb-0222222222222222"]

  instance_a = {
    ami_id    = "ami-XXXXXXXXXXXXXXXXX"
    subnet_id = "subnet-0aaaaaaaaaaaaaaaa"
  }

  instance_b = {
    ami_id    = "ami-XXXXXXXXXXXXXXXXX"
    subnet_id = "subnet-0bbbbbbbbbbbbbbb"
  }
}
```

## Example: cluster with CloudWatch log shipping and VPC CIDR access

```hcl
module "zeronat" {
  source  = "registry.terraform.io/zeronat-io/zeronat/aws"
  version = "~> 1.0"

  name            = "prod"
  vpc_id          = "vpc-0abc1234def56789a"
  mode            = "cluster"
  instance_type   = "t4g.small"
  vpc_cidr        = "10.0.0.0/16"
  route_table_ids = ["rtb-0111111111111111", "rtb-0222222222222222"]

  instance_a = {
    ami_id    = "ami-XXXXXXXXXXXXXXXXX"
    subnet_id = "subnet-0aaaaaaaaaaaaaaaa"
  }

  instance_b = {
    ami_id    = "ami-XXXXXXXXXXXXXXXXX"
    subnet_id = "subnet-0bbbbbbbbbbbbbbb"
  }

  cloudwatch_log_group          = "zeronat"
  cloudwatch_log_retention_days = 90

  tags = {
    Environment = "production"
    Team        = "platform"
  }
}
```

---

## Agent environment variables

The agent reads configuration from three sources in order of increasing priority:
hardcoded defaults → EC2 user-data (KEY=VALUE lines) → environment variables.

Environment variables are typically set via the systemd `EnvironmentFile`
(`/etc/zeronat/agent.env`). The Terraform module writes this file from the
`instance_a` / `instance_b` user-data blocks, so you generally do not need to
set them manually. They are documented here for operators who run the agent
outside the Terraform module or need to override a specific value.

| Variable | Default | Description |
|---|---|---|
| `ZERONAT_HA_ENABLED` | `false` | Enable Active/Standby HA mode. Set to `true` on both nodes in a cluster. |
| `ZERONAT_TAKEOVER_ON_BOOT` | `false` | Force this node to claim the Active role when the agent starts, regardless of what the peer is doing. |
| `ZERONAT_CONTROL_PORT` | `7946` | TCP port for the peer control plane (heartbeat and role negotiation). Must match on both nodes. |
| `ZERONAT_HEARTBEAT_INTERVAL` | `1s` | How often heartbeats are sent to the peer. Go duration string (e.g. `500ms`, `2s`). |
| `ZERONAT_DEAD_THRESHOLD` | `3` | Number of consecutive missed heartbeats before the peer is declared dead and failover is triggered. |
| `ZERONAT_PEER_SCAN_INTERVAL` | `60s` | How often the agent re-scans EC2 tags to (re-)discover the peer. Go duration string. |
| `ZERONAT_GROUP_TAG_KEY` | `zeronat:group` | EC2 tag key used for peer discovery. Must match on both nodes and align with the tag the Terraform module sets. |
| `ZERONAT_METRICS_ADDR` | `:9100` | Listen address for the Prometheus `/metrics` endpoint. |
| `ZERONAT_WEB_ADDR` | `127.0.0.1:8080` | Listen address for the web UI. Set to `0.0.0.0:8080` to allow access from within the VPC. |
| `ZERONAT_WEB_USER` | `admin` | Username for web UI Basic Auth. |
| `ZERONAT_WEB_PASSWORD` | _(none)_ | Password for web UI Basic Auth. When empty, Basic Auth is disabled and the web UI is open to anyone who can reach the port. |
| `ZERONAT_WEB_TLS_CERT` | _(auto-generate)_ | Path to a PEM-encoded TLS certificate for the web UI. When empty, the agent generates a self-signed certificate on startup. |
| `ZERONAT_WEB_TLS_KEY` | _(auto-generate)_ | Path to the PEM-encoded private key matching `ZERONAT_WEB_TLS_CERT`. |
| `ZERONAT_RT_SCAN_INTERVAL` | `30s` | How often to refresh route table state from the AWS API. Go duration string. |
| `ZERONAT_SHUTDOWN_ACK_TIMEOUT` | `5s` | How long to wait for the peer to acknowledge a graceful takeover before the agent exits anyway. Go duration string. |
| `ZERONAT_CLOUD_PROVIDER` | _(auto-detect)_ | Override cloud provider detection. Valid values: `aws`, `azure`, `gcp`, `none`. Useful in environments where IMDS probing is slow or blocked. |
| `ZERONAT_INSTANCE_ID` | _(from IMDS)_ | Override the EC2 instance ID used as the `instance_id` label on Prometheus metrics. Falls back to hostname if IMDS is unreachable and this variable is unset. |
