# Cluster Per AZ

Two independent HA clusters — one per Availability Zone — each managing its own private route table.

![Cluster Per AZ topology](topology.svg)

## Topology

- **VPC** with `10.0.0.0/16` CIDR
- **2 public subnets** (one per AZ) — each hosts both nodes of its AZ's cluster
- **2 private subnets** (one per AZ) — each routed through its local cluster
- **2 independent HA clusters**, each with its own EIP

Each cluster's two nodes share the same public subnet (same AZ). If the active node in an AZ fails, the standby within that AZ takes over. An AZ-level failure only affects that AZ's NAT — the other AZ continues uninterrupted.

## When to use

Use this topology when you need **both HA and AZ isolation**. No cross-AZ NAT traffic occurs during normal operation, which avoids cross-AZ data transfer charges and keeps latency minimal. This is the most resilient topology ZeroNAT supports.

## Usage

```bash
terraform init
terraform apply \
  -var="zeronat_ami_id=ami-xxxxx" \
  -var="test_ami_id=ami-yyyyy"
```

## Inputs

| Name | Description | Type | Default |
|---|---|---|---|
| `region` | AWS region to deploy into | `string` | `"eu-west-2"` |
| `zeronat_ami_id` | AMI ID for ZeroNAT instances (pre-baked with the agent) | `string` | — |
| `test_ami_id` | AMI ID for test instances (e.g. Amazon Linux 2023 ARM64) | `string` | — |
| `key_name` | SSH key pair name. Omit to disable SSH access | `string` | `null` |

## Outputs

| Name | Description |
|---|---|
| `cluster_a_instance_a_id` | Cluster A — Instance A ID |
| `cluster_a_instance_b_id` | Cluster A — Instance B ID |
| `cluster_b_instance_a_id` | Cluster B — Instance A ID |
| `cluster_b_instance_b_id` | Cluster B — Instance B ID |
| `cluster_a_instance_a_private_ip` | Cluster A — Instance A private IP |
| `cluster_a_instance_b_private_ip` | Cluster A — Instance B private IP |
| `cluster_b_instance_a_private_ip` | Cluster B — Instance A private IP |
| `cluster_b_instance_b_private_ip` | Cluster B — Instance B private IP |
| `test_a_private_ip` | Test instance A private IP |
| `test_b_private_ip` | Test instance B private IP |
