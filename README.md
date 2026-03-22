# ZeroNAT

A highly available NAT appliance for AWS VPC. Two ARM64 nodes across availability zones
with a shared Elastic IP. Sub-second failover via EIP reassociation and route table
re-pointing.

---

## The problem with AWS NAT Gateway

AWS NAT Gateway charges $0.045 per GB of data processed. That charge is on top of
EC2 data transfer. On a workload pushing 10 TB/month outbound, that is $450/month
just for the NAT function — before any EC2 costs.

ZeroNAT runs on two `t4g.small` instances (approximately $26/month combined) and
does the same job. It adds stateful high availability: if one node fails, the other
takes over in under a second and existing connections survive.

Open-source alternatives like `fck-nat` and `AlterNAT` eliminate the per-GB cost
but do not handle failover transparently — they drop connections when a node is
replaced. ZeroNAT does not.

---

## How it works

```
Private subnets
      │
      ▼  (0.0.0.0/0 route → ZeroNAT ENI)
 ┌────────────────────────────────────┐
 │  Active node (AZ-a)                │
 │  nftables MASQUERADE               │
 │  Shared EIP ◄──────────────────── │──── Standby node (AZ-b)
 │  Agent (health + route control)    │     (ready to claim EIP + routes)
 └────────────────────────────────────┘
      │
      ▼
   Internet
```

Both nodes run continuously. The active node owns the `0.0.0.0/0` route entry
pointing at its ENI and holds the shared Elastic IP.
When the active node becomes unreachable, the standby reassociates the EIP to
itself and calls `ec2:ReplaceRoute` to re-point all managed route tables to its
own ENI. Traffic continues flowing within sub-second failover time.

The agent binary is distributed via the [AWS Marketplace AMI](#marketplace).
The Terraform modules, OS configuration, and nftables ruleset in this repository
are Apache 2.0 licensed.

---

## Quick start

**Prerequisites:** AWS account, Terraform ≥ 1.5, an active ZeroNAT Marketplace
subscription.

```hcl
module "zeronat" {
  source  = "registry.terraform.io/zeronat-io/zeronat/aws"
  version = "~> 1.0"

  name   = "prod"
  vpc_id = "vpc-0abc123"
  mode   = "cluster"

  instance_a = {
    ami_id    = "ami-<zeronat-ami-id>"   # from Marketplace
    subnet_id = "subnet-0pub-az-a"
  }

  instance_b = {
    ami_id    = "ami-<zeronat-ami-id>"
    subnet_id = "subnet-0pub-az-b"
  }

  route_table_ids = [
    "rtb-private-az-a",
    "rtb-private-az-b",
  ]
}
```

See [docs/quickstart.md](docs/quickstart.md) for the full step-by-step guide,
including how to subscribe on Marketplace and verify the setup.

---

## Documentation

| Document | Contents |
|---|---|
| [Quick Start](docs/quickstart.md) | End-to-end setup in under 30 minutes |
| [Architecture](docs/architecture.md) | Traffic flow, Active/Standby topology, failover sequence |
| [Configuration](docs/configuration.md) | All Terraform module variables |
| [IAM Permissions](docs/iam-permissions.md) | Exact AWS API permissions the agent uses, with policy JSON |
| [Failover](docs/failover.md) | What triggers failover, how long it takes, how to test it |
| [Metrics](docs/metrics.md) | Prometheus metrics reference |
| [Logging](docs/logging.md) | Log format, journald, shipping logs off-instance |
| [FQDN Filtering](docs/fqdn-filtering.md) | Restrict outbound traffic by domain name |
| [Web UI & Terminal Dashboard](docs/webui.md) | Built-in dashboard: access, auth, TLS, API endpoints |
| [Upgrade](docs/upgrade.md) | Upgrade to a new AMI version without dropping connections |
| [Troubleshooting](docs/troubleshooting.md) | Common failure modes and how to diagnose them |

---

## Marketplace

Subscribe at: https://aws.amazon.com/marketplace/pp/prodview-zeronat

The AMI includes:
- Pre-hardened Amazon Linux 2023 (ARM64)
- ZeroNAT agent binary (signed, SLSA provenance)
- `nftables`, `amazon-cloudwatch-agent` pre-installed
- CIS Level 1 hardening applied
- AWS Inspector scan report attached to the listing

---

## Security

The nftables ruleset that handles all traffic is in [`os-config/nftables.conf.tmpl`](os-config/nftables.conf.tmpl).
It performs POSTROUTING MASQUERADE and nothing else. No traffic inspection, no payload
logging, no redirect — except for the explicitly documented [FQDN filter](docs/fqdn-filtering.md),
which is disabled by default. The template variables (VPC CIDR and interface name) are
populated at first boot from EC2 IMDS.

To report a security vulnerability: see [SECURITY.md](SECURITY.md).

---

## License

Apache 2.0 — see [LICENSE](LICENSE).

This covers the Terraform modules, OS configuration, and all content in this repository.
The ZeroNAT agent binary distributed via Marketplace is covered by a separate EULA.
