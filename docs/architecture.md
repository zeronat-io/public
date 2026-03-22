# Architecture

---

## Overview

ZeroNAT replaces the AWS Managed NAT Gateway with two EC2 instances (ARM64
Graviton) running `nftables` for packet masquerading and a control plane agent
for route management and failover.

The key difference from simpler NAT instances (fck-nat, AlterNAT) is that both
nodes continuously mirror their conntrack tables. When the active node fails,
the standby takes over the route **and** already has the full connection state,
so long-lived connections (database queries, file transfers, SSH sessions) do
not drop.

---

## Traffic flow

```
Private subnet EC2 instances
          │
          │  outbound traffic (0.0.0.0/0)
          ▼
  VPC Route Table
  0.0.0.0/0 → eni-ACTIVE (ZeroNAT active node ENI)
          │
          ▼
  ┌───────────────────────────────┐
  │  ZeroNAT Active Node (AZ-a)   │
  │                               │
  │  nftables:                    │
  │    FORWARD: accept            │
  │    POSTROUTING: MASQUERADE    │
  │                               │
  │  Source IP becomes:           │
  │    node's public IP           │
  └───────────────────────────────┘
          │
          ▼
     Internet Gateway
          │
          ▼
       Internet
```

Return traffic takes the reverse path. The connection is tracked by the kernel's
conntrack table; the node knows to route the reply back to the originating
private IP.

---

## Active/Standby topology

```
                    VPC Route Tables
                    0.0.0.0/0 → eni-A
                         │
          ┌──────────────┘
          │
  ┌───────▼──────────┐        ┌──────────────────┐
  │  Node A (AZ-a)   │        │  Node B (AZ-b)   │
  │                  │◄──────►│                  │
  │  Role: ACTIVE    │  TCP   │  Role: STANDBY   │
  │                  │  :7946 │                  │
  └──────────────────┘        └──────────────────┘
          │                          │
          │  conntrack state sync    │
          └──────────────────────────┘
               UDP :3780 (unicast)
```

Only the active node owns the `0.0.0.0/0` route entries and the shared Elastic
IP. Both nodes:
- Run `nftables` with identical rulesets
- Run the ZeroNAT agent, which monitors health and manages AWS route entries

The standby node is ready to forward traffic at any moment — it just does not
have a route or EIP pointing at it yet.

---

## Peer discovery

The agent discovers its peer by calling `ec2:DescribeInstances` and filtering
on a group tag (default key: `zeronat:group`). Both nodes in a cluster share
the same tag value, set by Terraform.

No subnet scanning, no multicast, no central coordination service. Each node
queries AWS at boot and periodically re-scans (default: every 60 seconds) to
handle peer replacement.

---

## Health checking

Each node runs two health checks in parallel:

1. **External reachability check**: the node pings `1.1.1.1` every second.
   If this fails, the node considers itself unhealthy and yields the ACTIVE
   role if it holds it.

2. **Peer heartbeat**: the active and standby nodes exchange TCP heartbeat
   messages every second (configurable). If the active node misses 3
   consecutive heartbeats (configurable), the standby declares it dead and
   initiates failover.

---

## Failover sequence

When the standby decides the active node is unreachable:

1. Standby reassociates the shared Elastic IP to its own ENI.
2. Standby calls `ec2:ReplaceRoute` for each managed route table, pointing
   `0.0.0.0/0` at its own ENI.
3. Standby transitions its local role to ACTIVE.
4. Traffic from private subnets now arrives at the new active node.
5. The public IP stays the same (shared EIP), so external allowlists and
   return traffic continue working. TCP clients reconnect via retransmission.

Total route update time: under one second in practice, limited primarily by
the `ec2:ReplaceRoute` API call latency (~100–300 ms).

---

## Shared Elastic IP

The Terraform module allocates a single Elastic IP shared between both nodes.
During normal operation, the EIP is associated with the active node's ENI.

On failover, the new active node calls `ec2:AssociateAddress` to claim the EIP
before updating the route tables. Because the public IP does not change,
external services that allowlist by IP continue working without reconfiguration.

The kernel's `nf_conntrack_tcp_loose=1` sysctl allows MASQUERADE to pick up
mid-stream TCP connections from client retransmits, so most existing
connections recover automatically without a new handshake.

---

## nftables ruleset

The complete ruleset is published at [`os-config/nftables.conf.tmpl`](../os-config/nftables.conf.tmpl).
The template variables (`.VpcCIDR`, `.PrimaryIF`) are populated at first boot from EC2 IMDS.

In short:
- `FORWARD` chain: accept all forwarded packets (private ↔ internet)
- `POSTROUTING` chain: MASQUERADE all outbound traffic leaving the public interface
- No traffic inspection, no payload logging, no redirect

If the FQDN egress filter is enabled, one additional rule is inserted that
queues new TCP connections on ports 80 and 443 to the agent for domain-name
classification. Return traffic is not queued. See [fqdn-filtering.md](fqdn-filtering.md).

---

## Agent process isolation

The agent runs as a dedicated `zeronat` system account — not `root` and not
`ec2-user`. The account has no login shell and no home directory. Network
privileges (`CAP_NET_ADMIN`, `CAP_NET_RAW`) are granted via systemd ambient
capabilities so the process can manage nftables rules and raw sockets without
needng UID 0.

The writable directories (`/var/lib/zeronat`, `/etc/zeronat`, `/run/zeronat`)
are owned by `zeronat:zeronat`. All other filesystem paths are read-only for
the service.

---

## AWS API calls

The agent makes the following AWS API calls. All are constrained by the
least-privilege IAM policy the Terraform module creates:

| API call | When | Purpose |
|---|---|---|
| `ec2:DescribeInstances` | Boot, then every 60 s | Peer discovery via group tag |
| `ec2:DescribeRouteTables` | Boot | Discover managed route tables via group tag |
| `ec2:ReplaceRoute` | Failover | Point `0.0.0.0/0` at own ENI |
| `ec2:CreateRoute` | Boot (if no default route exists) | Create initial `0.0.0.0/0` route |
| `cloudwatch:GetMetricData` | Periodically | CPU credit monitoring on T-series instances |

See [iam-permissions.md](iam-permissions.md) for the full policy document.
