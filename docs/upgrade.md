# Upgrading ZeroNAT

This guide covers upgrading both nodes to a new AMI version without dropping
connections.

The procedure replaces one node at a time. While one node is being replaced,
the other handles all traffic. Existing TCP connections from private subnets
continue without interruption through the node that stays up.

---

## Before you start

- Verify the new AMI ID for your region from the Marketplace listing
- Read the [CHANGELOG](../CHANGELOG.md) for the release you are upgrading to
- Confirm both nodes are healthy before starting:

```bash
# On each node
systemctl status zeronat-agent
journalctl -u zeronat-agent -n 20
```

Both nodes should show their role (`ACTIVE` or `STANDBY`) without errors.

---

## Step 1: Update Terraform with the new AMI

Update your module block with the new AMI ID:

```hcl
module "zeronat" {
  # ...
  instance_a = {
    ami_id    = "ami-YYYYYYYYYYYYYYYYY"   # new version
    subnet_id = "subnet-0aaaaaaaaaaaaaaaa"
  }
  instance_b = {
    ami_id    = "ami-YYYYYYYYYYYYYYYYY"   # same new version
    subnet_id = "subnet-0bbbbbbbbbbbbbbb"
  }
}
```

Do not `terraform apply` yet — apply is done manually per node in the steps below.

---

## Step 2: Replace the standby node

In Terraform, use `replace` targeting to replace only the standby instance. The
standby is whichever node does not currently own the routes. Check:

```bash
aws ec2 describe-route-tables \
  --route-table-ids <your-route-table-id> \
  --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NetworkInterfaceId'
```

Match the ENI to an instance ID to identify the active node. The other node is
the standby.

Replace the standby:
```bash
terraform apply -replace='module.zeronat.aws_instance.b'
```

(Or `aws_instance.a` if node A is standby.)

Terraform terminates the old standby instance and starts a new one with the
updated AMI. The new instance boots, discovers the active peer, and joins as
standby. Monitor its logs:

```bash
journalctl -u zeronat-agent -f
```

Wait until you see:
```
Peer discovered  peer_ip=10.0.1.x
Transitioning to STANDBY  reason=peer_is_active
conntrackd sync: bulk transfer complete
```

The new standby is now running the updated version and has a full copy of the
active node's conntrack state.

---

## Step 3: Fail over to the new standby

Now move traffic to the updated node by restarting the agent on the active node:

```bash
# SSH into the currently active node
sudo systemctl restart zeronat-agent
```

During the restart window (a few seconds), the new standby detects the peer is
unresponsive and takes over. It calls `ec2:ReplaceRoute` and becomes the new
active node.

Verify:
```bash
# On the new active node (previously standby, running new AMI)
journalctl -u zeronat-agent -n 20 | grep -E "ACTIVE|STANDBY|ReplaceRoute"
```

Verify traffic continues from a private subnet:
```bash
curl https://checkip.amazonaws.com
```

---

## Step 4: Replace the remaining node

The old active node has restarted its agent and rejoined as standby (running
the old AMI). Replace it now:

```bash
terraform apply -replace='module.zeronat.aws_instance.a'
```

Wait for it to join as standby with the new AMI, same as Step 2.

---

## Step 5: Verify

Both nodes are now running the new AMI. Confirm:

```bash
# On each node
cat /etc/zeronat-release       # or: zeronat-agent --version
systemctl status zeronat-agent
```

Check logs on both nodes for any errors. Run a failover test (see
[failover.md](failover.md)) to confirm the updated cluster is healthy.

---

## Rollback

If the new AMI exhibits problems, repeat the procedure using the previous AMI
ID. The process is identical — replace the standby first, fail over, replace
the other node.

Because conntrack state is mirrored continuously, rolling back to the previous
version also does not drop connections.
