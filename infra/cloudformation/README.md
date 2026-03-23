# ZeroNAT CloudFormation Templates

Deploy a ZeroNAT NAT appliance on AWS using CloudFormation. Two self-contained templates are available:

- **single-basic** — one NAT instance, no failover (dev/test)
- **cluster-basic** — two instances across AZs with sub-second failover (production)

Each template creates a complete VPC with subnets, route tables, security groups, IAM roles, and test instances — ready to verify in minutes.

---

## Single Instance

One ZeroNAT node in a public subnet. Two private subnets share a single route table. No HA, no peer discovery.

<!-- TODO: Replace with actual architecture diagram -->
![Single instance architecture](diagrams/single-basic.svg)

### Quick Launch

[<img src="https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png" alt="Launch single-basic stack">](https://console.aws.amazon.com/cloudformation/home#/stacks/create/review?stackName=zeronat-single&templateURL=https://raw.githubusercontent.com/zeronat-io/public/main/infra/cloudformation/single-basic.yaml)

### CLI Deploy

```bash
aws cloudformation create-stack \
  --stack-name zeronat-single \
  --template-body file://single-basic.yaml \
  --parameters \
    ParameterKey=ZeroNATAmiId,ParameterValue=ami-XXXXXXXXXXXXXXXXX \
    ParameterKey=TestAmiId,ParameterValue=ami-XXXXXXXXXXXXXXXXX \
    ParameterKey=KeyName,ParameterValue=my-key \
  --capabilities CAPABILITY_NAMED_IAM
```

---

## HA Cluster

Two ZeroNAT nodes across AZs with automatic failover. Each AZ gets its own private route table. The active node creates the default routes at boot; if it fails, the standby takes over all routes and the shared Elastic IP.

<!-- TODO: Replace with actual architecture diagram -->
![Cluster architecture](diagrams/cluster-basic.svg)

### Quick Launch

[<img src="https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png" alt="Launch cluster-basic stack">](https://console.aws.amazon.com/cloudformation/home#/stacks/create/review?stackName=zeronat-cluster&templateURL=https://raw.githubusercontent.com/zeronat-io/public/main/infra/cloudformation/cluster-basic.yaml)

### CLI Deploy

```bash
aws cloudformation create-stack \
  --stack-name zeronat-cluster \
  --template-body file://cluster-basic.yaml \
  --parameters \
    ParameterKey=ZeroNATAmiId,ParameterValue=ami-XXXXXXXXXXXXXXXXX \
    ParameterKey=TestAmiId,ParameterValue=ami-XXXXXXXXXXXXXXXXX \
    ParameterKey=KeyName,ParameterValue=my-key \
  --capabilities CAPABILITY_NAMED_IAM
```

---

## Parameters

Both templates accept the same parameters:

| Parameter | Required | Default | Description |
|---|---|---|---|
| `ZeroNATAmiId` | Yes | — | ZeroNAT AMI ID (pre-baked with the agent) |
| `TestAmiId` | Yes | — | AMI for test instances (e.g. Amazon Linux 2023 ARM64) |
| `InstanceType` | No | `t4g.micro` | EC2 instance type for ZeroNAT node(s) |
| `KeyName` | No | *(empty)* | SSH key pair name. Leave empty to disable SSH. |

---

## What Gets Created

### single-basic

| Resource | Details |
|---|---|
| VPC | 10.0.0.0/16 with DNS support |
| Subnets | 1 public, 2 private (across 2 AZs) |
| Route tables | 1 public (→ IGW), 1 private (→ ZeroNAT ENI, managed by agent) |
| ZeroNAT instance | Single node in public subnet, source/dest check disabled |
| Elastic IP | Associated with the ZeroNAT instance |
| IAM role | Least-privilege: DescribeInstances, DescribeRouteTables, ReplaceRoute, CreateRoute, EIP failover, CloudWatch metrics |
| Security group | Egress all, ingress from VPC (NAT traffic, metrics :9100, web UI :8080, SSH :22) |
| Test instances | One per private subnet (t4g.nano) |

### cluster-basic

Same as above, plus:

| Resource | Details |
|---|---|
| Second public subnet | AZ-b, for the standby node |
| Second private route table | Per-AZ route tables (both managed by the cluster) |
| Instance B (standby) | Second node in AZ-b, no TAKEOVER_ON_BOOT |
| Peer control SG rule | TCP 7946 self-referencing (heartbeat between nodes) |

---

## Verify Connectivity

After the stack reaches `CREATE_COMPLETE`, SSH into a test instance via the ZeroNAT node (or use SSM Session Manager) and verify egress:

```bash
# From a test instance in a private subnet
curl -s https://ifconfig.me
# Should return the Elastic IP address shown in the stack outputs
```

Check the ZeroNAT web dashboard at `http://<zeronat-private-ip>:8080` from within the VPC.

---

## Cleanup

```bash
aws cloudformation delete-stack --stack-name zeronat-single
# or
aws cloudformation delete-stack --stack-name zeronat-cluster
```

All resources (VPC, instances, EIP, IAM role) are deleted with the stack.

---

## Differences from the Terraform Module

These templates are self-contained examples equivalent to the Terraform examples in `infra/terraform/aws/examples/`. They create a complete VPC for evaluation purposes.

For production use with an existing VPC, use the [Terraform module](../terraform/aws/) which offers full configurability (custom VPC, gradual NAT Gateway migration, CloudWatch logging, external IAM, etc.).
