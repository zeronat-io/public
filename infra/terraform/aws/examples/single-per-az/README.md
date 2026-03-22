# Single Per AZ

Two independent single-mode ZeroNAT instances — one per Availability Zone — each with its own route table.

![Single Per AZ topology](topology.svg)

## Topology

- **VPC** with `10.0.0.0/16` CIDR
- **2 public subnets** (one per AZ) — each hosts a ZeroNAT instance
- **2 private subnets** (one per AZ) — each routed through its local ZeroNAT instance
- **No HA** — if an instance fails, that AZ loses NAT

Each ZeroNAT instance manages only its AZ's private route table, so egress traffic stays AZ-local and avoids cross-AZ data transfer charges.

## When to use

Use this for **cost-optimized, AZ-local NAT** when you want to avoid cross-AZ traffic but don't need failover within each AZ. Suitable for workloads that can tolerate brief NAT outages (e.g. batch processing, non-latency-sensitive services).

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
| `nat_a_instance_id` | ZeroNAT instance A ID |
| `nat_b_instance_id` | ZeroNAT instance B ID |
| `nat_a_private_ip` | ZeroNAT instance A private IP |
| `nat_b_private_ip` | ZeroNAT instance B private IP |
| `test_a_private_ip` | Test instance A private IP |
| `test_b_private_ip` | Test instance B private IP |
