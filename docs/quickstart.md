# Quick Start

This guide walks through deploying a two-node ZeroNAT cluster from scratch. It
takes about 30 minutes.

**Prerequisites:**
- An AWS account
- Terraform ≥ 1.5 installed locally
- An active ZeroNAT subscription on AWS Marketplace

---

## Step 1: Subscribe on AWS Marketplace

Go to the [ZeroNAT Marketplace listing](https://aws.amazon.com/marketplace/pp/prodview-zeronat)
and click **Continue to Subscribe**. Accept the EULA. You are not charged until
instances are running.

Once subscribed, go to **Continue to Configuration**, select your preferred region,
and note the AMI ID. You will need it in the Terraform config.

---

## Step 2: Prepare your VPC

ZeroNAT nodes live in **public subnets** (they need an internet route to forward
traffic). The private subnets in your VPC should currently have a `0.0.0.0/0`
route pointing at an AWS NAT Gateway, a NAT instance, or no default route at all.

You will need:
- Two public subnet IDs (one per AZ)
- One or more private subnet route table IDs
- Your VPC ID

---

## Step 3: Add the Terraform module

```hcl
module "zeronat" {
  source  = "registry.terraform.io/zeronat-io/zeronat/aws"
  version = "~> 1.0"

  name   = "prod"
  vpc_id = "vpc-0abc1234def56789a"
  mode   = "cluster"

  instance_a = {
    ami_id    = "ami-XXXXXXXXXXXXXXXXX"   # from Step 1, for your region
    subnet_id = "subnet-0aaaaaaaaaaaaaaaa" # public subnet, AZ-a
  }

  instance_b = {
    ami_id    = "ami-XXXXXXXXXXXXXXXXX"
    subnet_id = "subnet-0bbbbbbbbbbbbbbb" # public subnet, AZ-b
  }

  route_table_ids = [
    "rtb-0111111111111111",   # private subnet route table, AZ-a
    "rtb-0222222222222222",   # private subnet route table, AZ-b
  ]
}

output "zeronat_instance_ids" {
  value = module.zeronat.instance_ids
}
```

Run:
```bash
terraform init
terraform plan
terraform apply
```

Terraform creates:
- Two EC2 instances (ARM64 `t4g.micro` by default)
- An IAM role and instance profile with least-privilege permissions
- A security group allowing the nodes to talk to each other (heartbeat)
- EC2 tags that the agent uses for peer discovery

---

## Step 4: Verify the instances are healthy

SSH into one of the nodes (if you set `key_name` in the module) or use EC2
Instance Connect:

```bash
# Check the agent is running
systemctl status zeronat-agent

# Check it has taken the ACTIVE role
journalctl -u zeronat-agent -n 50 | grep -E "ACTIVE|STANDBY|role"
```

Expected output on the primary node:
```
Transitioning to ACTIVE  reason=initial_boot
```

Check that the route table has been updated:
```bash
aws ec2 describe-route-tables \
  --route-table-ids rtb-0111111111111111 \
  --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`]'
```

The `NetworkInterfaceId` should point to the ENI of the active node.

---

## Step 5: Verify traffic flows

From an instance in a private subnet:
```bash
curl -s https://checkip.amazonaws.com
```

If it returns an IP address, traffic is flowing through ZeroNAT.

---

## Step 6: Test failover (optional but recommended)

Stop the active instance:
```bash
aws ec2 stop-instances --instance-ids <active-instance-id>
```

Within a second or two, the standby should take over. Watch from the standby:
```bash
journalctl -u zeronat-agent -f | grep -E "ACTIVE|STANDBY|failover"
```

Then verify private subnet traffic still flows:
```bash
# from a private subnet instance
curl -s https://checkip.amazonaws.com
```

Start the stopped instance again and it will rejoin as standby.

---

## Removing an existing NAT Gateway

If you currently have an AWS NAT Gateway, do not remove it until ZeroNAT is
verified working. Use `active_route_table_ids` to migrate one subnet at a time:

```hcl
module "zeronat" {
  # ...
  route_table_ids = [
    "rtb-0111111111111111",
    "rtb-0222222222222222",
  ]
  # Only take over one route table initially
  active_route_table_ids = ["rtb-0111111111111111"]
}
```

Once verified, expand `active_route_table_ids` to cover the remaining tables,
then terminate the NAT Gateway.

---

## Next steps

- [Configuration reference](configuration.md) — all module variables
- [Failover behaviour](failover.md) — what happens when a node fails
- [Metrics](metrics.md) — Prometheus metrics and example queries
- [Troubleshooting](troubleshooting.md) — if something is not working
