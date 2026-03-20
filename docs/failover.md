# Failover

This document covers Active/Standby behaviour from the operator's perspective:
what triggers a failover, how long it takes, what happens to existing
connections, how to test it, and how to force a manual role swap.

---

## Normal operation

Both nodes run continuously. One holds the `ACTIVE` role, the other `STANDBY`.

The active node:
- Owns the `0.0.0.0/0` route entries in all managed route tables (pointing at
  its own ENI)
- Forwards and masquerades all outbound traffic from private subnets

The standby node:
- Mirrors the active node's conntrack table continuously via `conntrackd`
- Monitors the active node's health via TCP heartbeat
- Is ready to take over at any moment

---

## What triggers an automatic failover

The standby node initiates a failover when either of these conditions is met:

**1. Peer heartbeat timeout**
The active node stops responding to TCP heartbeat messages. The standby waits
for 3 consecutive missed heartbeats (default: 3 seconds total) before acting.
This covers: instance crash, kernel panic, instance stop/terminate, network
failure between nodes, agent process crash.

**2. Active node reports itself unhealthy**
If the active node loses external reachability (can't reach `1.1.1.1`), it
voluntarily yields the ACTIVE role by sending a notification to the standby.
The standby then takes over within one heartbeat interval.

---

## Failover sequence

1. Standby detects the active node is unreachable (timeout or notification)
2. Standby calls `ec2:ReplaceRoute` for each managed route table, pointing
   `0.0.0.0/0` at its own ENI
3. Standby transitions its local role to ACTIVE
4. Traffic from private subnets begins arriving at the new active node
5. Existing connections continue without reset — conntrack state was already
   present on the standby

**Total time**: typically under one second. The dominant factor is the
`ec2:ReplaceRoute` API call latency, usually 100–300 ms. The route table update
propagates to the VPC data plane in under 100 ms after the API call returns.

---

## What happens to existing connections

Because `conntrackd` continuously mirrors all connection state from the active
to the standby, the standby's conntrack table is already populated when it takes
over. Packets from private subnets that arrive mid-connection are handled
correctly — the kernel knows the correct source-NAT mapping and applies it.

**Practical result**: TCP connections that were established before the failover
continue without needing to reconnect. Long-lived connections (database sessions,
file transfers, SSH tunnels through the NAT) survive.

**Edge case**: connections established within the microseconds between the last
conntrack sync and the route table switch may not have been replicated yet.
These will need to reconnect. In practice this window is extremely small.

---

## What triggers role assignment at boot

When a node boots:

1. The agent queries EC2 tags to find its peer.
2. If the peer is unreachable or does not yet exist, the booting node takes
   `ACTIVE` immediately and claims the routes.
3. If the peer is already `ACTIVE` and reachable, the booting node joins as
   `STANDBY` and begins mirroring conntrack state.

This means replacing a failed node is self-healing: start a new instance with
the same AMI and tags, and it will join as standby automatically.

---

## Testing failover

**Stop the active instance:**
```bash
aws ec2 stop-instances --instance-ids <active-instance-id>
```

Watch the standby take over:
```bash
# SSH into the standby node
journalctl -u zeronat-agent -f
```

Expected log output on the standby:
```
peer heartbeat timeout  peer_ip=10.0.1.x missed=3
Transitioning to ACTIVE  reason=peer_timeout
ReplaceRoute succeeded   route_table=rtb-0111111111111111
```

Verify traffic still flows from a private subnet instance:
```bash
curl https://checkip.amazonaws.com
```

Restart the stopped instance. It will rejoin as standby automatically:
```
Peer discovered  peer_ip=10.0.1.x
Transitioning to STANDBY  reason=peer_is_active
```

---

## Forcing a manual role swap

There is no explicit "swap roles" command in the current version. To gracefully
move the ACTIVE role to the standby node, stop or restart the agent on the
active node:

```bash
# On the active node
sudo systemctl restart zeronat-agent
```

When the agent restarts, it checks whether the peer is already active. If the
standby has taken over during the restart window (it will, given the heartbeat
timeout), the restarted node joins as standby.

To ensure the swap is clean, watch both nodes' logs during the operation.

---

## Failover-related log events

| Event | Node | Meaning |
|---|---|---|
| `Transitioning to ACTIVE  reason=initial_boot` | Either | Node took ACTIVE at boot (no peer found) |
| `Transitioning to ACTIVE  reason=peer_timeout` | Standby | Peer stopped heartbeating |
| `Transitioning to ACTIVE  reason=peer_unhealthy` | Standby | Peer reported itself unhealthy |
| `Transitioning to STANDBY  reason=peer_is_active` | Either | Peer is already active; this node yields |
| `peer heartbeat timeout  missed=N` | Standby | Peer hasn't heartbeated; counting down to failover |
| `ReplaceRoute succeeded` | Newly active | Route table updated successfully |
| `ReplaceRoute failed` | Newly active | AWS API call failed — check IAM permissions |
| `external health check failed` | Active | Can't reach 1.1.1.1; will yield if repeated |
