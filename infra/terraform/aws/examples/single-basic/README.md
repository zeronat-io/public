# Single Basic

Single ZeroNAT instance with one shared route table — the simplest possible setup.

![Single Basic topology](topology.svg)

## Topology

- **VPC** with `10.0.0.0/16` CIDR
- **1 public subnet** — ZeroNAT instance lives here
- **2 private subnets** (across AZs) — both share a single private route table
- **No HA**, no peer discovery

One ZeroNAT instance handles all egress for both private subnets via a single route table entry. If the instance fails, NAT is unavailable until it recovers.

## When to use

Use this for **development, testing, or non-critical environments** where cost matters more than availability. It is also a good starting point for evaluating ZeroNAT before moving to a cluster topology.

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
| `nat_instance_a_id` | ZeroNAT instance ID |
| `nat_instance_a_private_ip` | ZeroNAT instance private IP |
| `test_instance_a_private_ip` | Test instance A private IP |
| `test_instance_b_private_ip` | Test instance B private IP |
