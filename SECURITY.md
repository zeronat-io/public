# Security Policy

## Reporting a Vulnerability

Email **security@zeronat.io** with the details.

Include:
- A description of the vulnerability and its potential impact
- Steps to reproduce (or a proof-of-concept if available)
- The version(s) affected

We will acknowledge receipt within **2 business days** and provide an initial
assessment within **5 business days**. We aim to ship a fix within **30 days**
of confirming a valid vulnerability, depending on severity and complexity.

We will coordinate disclosure timing with you before publishing anything publicly.

---

## Scope

**In scope:**
- The ZeroNAT agent binary (distributed via AWS Marketplace AMI)
- The Terraform modules in this repository
- The OS configuration and nftables ruleset in `os-config/`
- The documentation in `docs/`

**Out of scope:**
- AWS platform vulnerabilities (report to AWS Security)
- Vulnerabilities in third-party packages upstream (report to the package maintainer;
  we will update our dependency once a fix is available)
- Issues in the reviewer's own AWS environment configuration

---

## Supported Versions

We maintain security fixes for the current major version only. Users on older
major versions should upgrade.

---

## What the agent does to network traffic

ZeroNAT sits in the data path of all outbound traffic from private subnets.
Security concerns about what the appliance does to that traffic are legitimate.

The nftables ruleset that processes all traffic is published at
[`os-config/nftables.conf.tmpl`](os-config/nftables.conf.tmpl). It performs POSTROUTING
MASQUERADE and nothing else. No payload inspection, no traffic logging, no
redirect — except for the explicitly documented FQDN egress filter, which is
**disabled by default** and only active when the operator configures it.
The template variables (VPC CIDR and interface name) are filled in at first boot
from EC2 IMDS; no rule logic changes between the template and the running instance.

The agent binary is not open-source, but its AWS API calls are constrained to
the least-privilege IAM policy published at
[`docs/iam-permissions.md`](docs/iam-permissions.md). You can enforce this
boundary by deploying the Terraform module, which creates that exact policy.
