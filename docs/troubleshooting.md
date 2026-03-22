# Troubleshooting

---

## Peer not discovered

**Symptom:** The agent logs `no peers found` at boot and the node stays `ACTIVE`
indefinitely, or the standby never appears.

**Check the group tag:**

Both nodes must have the same tag key and value. The Terraform module sets this
automatically, but if you are managing tags manually:

```bash
# On each node, read the group tag the agent is looking for
curl -s http://169.254.169.254/latest/user-data | grep ZERONAT_GROUP_TAG

# List instances with that tag
aws ec2 describe-instances \
  --filters "Name=tag:zeronat:group,Values=<your-group-value>" \
  --query 'Reservations[].Instances[].{ID:InstanceId,IP:PrivateIpAddress,State:State.Name}'
```

Both nodes should appear. If only one appears, the tag is missing or the value
does not match.

**Check IAM permissions:**

The agent needs `ec2:DescribeInstances`. If the instance profile is missing or
the policy does not include this action, peer discovery silently returns empty.

```bash
# Test from the instance
aws ec2 describe-instances \
  --filters "Name=tag:zeronat:group,Values=<your-group-value>"
```

If this returns an access denied error, fix the IAM policy. See
[iam-permissions.md](iam-permissions.md).

---

## Failover not triggering

**Symptom:** The active node is stopped or unreachable but the standby does not
take over, or takes longer than expected.

**Check heartbeat configuration:**

The standby waits for 3 missed heartbeats (at a 1-second interval by default)
before triggering failover. Total wait: ~3 seconds. If `dead_threshold` or
`heartbeat_interval` are configured to higher values in Terraform, failover
takes longer.

**Check security group:**

The nodes must be able to reach each other on the control port (default TCP
7946). If the security group does not allow this, heartbeats fail and failover
still triggers — but correctly identifying the peer as dead may take longer,
and peer discovery re-syncs may not work after recovery.

```bash
# From the standby, test TCP connectivity to the active node
nc -z -v <active-node-private-ip> 7946
```

**Check EIP association:**

If the EIP is not moving during failover, verify the agent has the required
`ec2:AssociateAddress` and `ec2:DisassociateAddress` IAM permissions.

The security group created by the Terraform module allows both ports between
the two nodes automatically.

---

## EIP failover not working

**Symptom:** Failover triggers but the public IP does not move to the new active
node, or external services see a different IP after failover.

**Check EIP association:**

```bash
aws ec2 describe-addresses --filters "Name=instance-id,Values=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)"
```

Common causes:
- Missing IAM permission `ec2:AssociateAddress` on the instance profile
- The EIP was not created by the Terraform module (check that the module is in
  `cluster` mode)
- Rate limiting on `ec2:AssociateAddress` API calls (rare, but possible during
  rapid failover cycling)

**Check that conntrack accounting is enabled (for byte metrics):**

```bash
cat /proc/sys/net/netfilter/nf_conntrack_acct
```

Should return `1`. The AMI sets this via sysctl at boot. If it is `0`, metrics
for `tx_bytes_per_ip` and `rx_bytes_per_ip` will be zero.

---

## Agent won't start

**Check systemd status:**

```bash
systemctl status zeronat-agent
journalctl -u zeronat-agent -n 50
```

**IMDS not reachable:**

The agent reads instance metadata at startup (instance ID, region, private IP).
If instance metadata is blocked (e.g. `HttpTokens=required` with no IMDSv2
handling), the agent fails at boot.

```bash
# Test IMDSv2 access
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id
```

**File permission error on `/var/lib/zeronat`, `/etc/zeronat`, or `/run/zeronat`:**

The agent runs as the `zeronat` system account. If these directories were
created manually and are owned by `root`, the agent cannot write to them and
will exit at startup. Fix ownership:

```bash
chown -R zeronat:zeronat /var/lib/zeronat /etc/zeronat /run/zeronat
```

The RPM `postinstall` script creates these directories with the correct
ownership. If you see this error it usually means the directories were
pre-created outside of the package installation.

**nftables pre-check failed:**

The agent verifies its nftables rules are correctly loaded before starting.
If the rules are missing or incorrect, it exits with an error.

```bash
nft list ruleset
```

You should see `table inet zeronat` with `forward` and `postrouting` chains.
If the table is missing, re-run the nftables setup:

```bash
systemctl restart nftables
```

**IAM permission denied at boot:**

The agent calls `ec2:DescribeInstances` and `ec2:DescribeRouteTables` at startup.
If these fail, it logs the error and exits.

```bash
journalctl -u zeronat-agent | grep -i "denied\|permission\|unauthorized"
```

Fix the IAM policy. See [iam-permissions.md](iam-permissions.md).

---

## Traffic not flowing through ZeroNAT

**Symptom:** Instances in private subnets cannot reach the internet, or traffic
is going through a NAT Gateway instead of ZeroNAT.

**Check the route table:**

```bash
aws ec2 describe-route-tables \
  --route-table-ids <private-subnet-route-table-id> \
  --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`]'
```

The `NetworkInterfaceId` should be the ENI of the active ZeroNAT node.

If it still points at a NAT Gateway, check whether the agent has the
`active_route_table_ids` variable configured and whether the route table ID
is in that list.

**Check IP forwarding:**

```bash
# On the ZeroNAT node
cat /proc/sys/net/ipv4/ip_forward
```

Should return `1`. If it is `0`:
```bash
sudo sysctl -w net.ipv4.ip_forward=1
```

This should not happen on the AMI (sysctl is set at boot) but can occur if the
sysctl configuration was modified.

**Check nftables:**

```bash
nft list ruleset | grep -A5 "postrouting"
```

You should see a `masquerade` rule. If the postrouting chain is empty or
missing, restart nftables:

```bash
systemctl restart nftables
systemctl restart zeronat-agent
```

---

## Metrics endpoint not reachable

**Symptom:** Prometheus cannot scrape `:9100/metrics`.

**Check the agent is running and listening:**

```bash
systemctl status zeronat-agent
ss -tlnp | grep 9100
```

**Check security group:**

The Terraform module allows inbound TCP 9100 from `vpc_cidr` if set, or from
the ZeroNAT security group only otherwise. If your Prometheus instance is
outside the security group and `vpc_cidr` is not set, add an inbound rule:

```hcl
additional_security_group_rules = [
  {
    type        = "ingress"
    protocol    = "tcp"
    from_port   = 9100
    to_port     = 9100
    cidr_blocks = ["10.0.0.0/8"]
    description = "Prometheus scrape"
  }
]
```

---

## Getting more information

If the above steps do not resolve the issue, collect the following before
opening an issue:

```bash
# Agent version
zeronat-agent --version

# Recent agent logs
journalctl -u zeronat-agent --since "1 hour ago" > agent.log

# nftables ruleset
nft list ruleset > nftables.txt

# Route tables (replace with your route table IDs)
aws ec2 describe-route-tables --route-table-ids rtb-... > route-tables.json
```

Email **support@zeronat.io** with this information attached.
