# Cluster Basic

HA pair of ZeroNAT instances deployed across two Availability Zones — the typical production setup.

![Cluster Basic topology](topology.svg)

## Topology

- **VPC** with `10.0.0.0/16` CIDR
- **2 public subnets** (one per AZ) — ZeroNAT nodes live here
- **2 private subnets** (one per AZ) — workloads route through ZeroNAT
- **1 shared Elastic IP** — migrates to the active node on failover
- **1 HA cluster** spanning both AZs with peer heartbeat

Both private route tables are managed by a single cluster. On failover the standby node re-points all `0.0.0.0/0` routes to its own ENI and claims the shared EIP, providing sub-second recovery.

## When to use

This is the **recommended production topology**. It covers most use cases where you need highly available egress from private subnets across multiple AZs with a single stable public IP.

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
| `nat_instance_a_id` | Instance A ID |
| `nat_instance_b_id` | Instance B ID |
| `nat_instance_a_private_ip` | Instance A private IP |
| `nat_instance_b_private_ip` | Instance B private IP |
| `nat_eip_public_ip` | Shared Elastic IP public address |
| `nat_eip_allocation_id` | Shared Elastic IP allocation ID |
| `test_a_private_ip` | Test instance A private IP |
| `test_b_private_ip` | Test instance B private IP |
