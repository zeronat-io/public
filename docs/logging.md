# ZeroNAT Logging Guide

ZeroNAT produces logs from two components: the control plane agent and the
conntrackd state sync daemon. This guide covers where logs are written, what the
key events mean, how log rotation works, and how to ship logs off-instance.

---

## Log Sources

### Control Plane Agent

The ZeroNAT agent writes structured JSON to stdout, which systemd captures into
journald.

**View live logs:**
```bash
journalctl -u zeronat-agent -f
```

**View recent logs:**
```bash
journalctl -u zeronat-agent --since "1 hour ago"
```

**Log format:**
```json
{"time":"2026-03-16T10:00:00Z","level":"INFO","component":"failover","msg":"Transitioning to ACTIVE","reason":"peer timeout"}
```

Key components logged: `healthcheck`, `discovery`, `failover`, `nftables`,
`api`, `webui`, `metrics`.

#### Events to watch for

| Level | Event | Meaning |
|---|---|---|
| `INFO` | `Transitioning to ACTIVE` | This node became the active NAT. Check `reason` field. |
| `INFO` | `Transitioning to STANDBY` | This node handed off to peer. Normal during graceful failover. |
| `WARN` | `peer heartbeat timeout` | Peer hasn't responded — failover may be imminent. |
| `WARN` | `external health check failed` | This node can't reach 1.1.1.1. May itself be unhealthy. |
| `ERROR` | `ReplaceRoute failed` | AWS API call to update the route table failed. Check IAM permissions. |
| `ERROR` | `PANIC in goroutine` | A background goroutine crashed. Agent stays running but the component is dead — restart the service. |
| `ERROR` | `PANIC — agent crashing` | Fatal panic in the main loop. systemd will restart the agent automatically. |

---

### conntrackd

conntrackd writes directly to `/var/log/conntrackd.log`. This file records
connection state sync events between the two nodes.

**View live:**
```bash
tail -f /var/log/conntrackd.log
```

**Typical content:** bulk state transfers on startup, incremental sync
statistics every few seconds, and warnings if sync falls behind.

---

## Log Rotation

Log rotation is configured in the AMI at `/etc/logrotate.d/zeronat-conntrackd`.

- `/var/log/conntrackd.log` rotates daily, keeps 7 days, compresses after 1 day.
- Rotation fires early if the file exceeds 50M (handles connection storms).
- Uses `copytruncate` — conntrackd does not need to be restarted after rotation.

The agent's logs (via journald) are capped at 200M total by
`/etc/systemd/journald.conf.d/zeronat.conf`, retained for up to 30 days.

---

## Shipping Logs Off-Instance

When an EC2 instance terminates, its local logs are gone. To retain logs across
instance replacements, ship them to a persistent destination before that happens.

The CloudWatch agent is pre-installed in the ZeroNAT AMI but ships no logs by
default. To enable log shipping:

### 1. Add IAM permissions to the instance profile

The instance role needs:
```json
{
  "Effect": "Allow",
  "Action": [
    "logs:CreateLogGroup",
    "logs:CreateLogStream",
    "logs:PutLogEvents",
    "logs:DescribeLogStreams"
  ],
  "Resource": "arn:aws:logs:<region>:<account-id>:log-group:/zeronat/*:*"
}
```

If you use the ZeroNAT Terraform module, set the `cloudwatch_log_group` variable
and the module adds these permissions automatically.

### 2. Create a CloudWatch agent config

Write the following to
`/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json` on each
instance (or distribute via user-data):

```json
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/conntrackd.log",
            "log_group_name": "/zeronat/conntrackd",
            "log_stream_name": "{instance_id}",
            "retention_in_days": 30
          }
        ]
      },
      "journald": {
        "collect_list": [
          {
            "log_group_name": "/zeronat/agent",
            "log_stream_name": "{instance_id}",
            "units": ["zeronat-agent.service"],
            "retention_in_days": 30
          }
        ]
      }
    }
  }
}
```

### 3. Start the agent

```bash
sudo systemctl enable --now amazon-cloudwatch-agent
```

Verify it's shipping:
```bash
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a status
```

### Alternatives

The CloudWatch agent is not required. Any log shipper that can read journald or
tail files works: Fluent Bit, Fluentd, Datadog Agent, Vector. The ZeroNAT AMI
does not prescribe a specific destination.

---

## Useful Log Queries (CloudWatch Logs Insights)

Find all failover events:
```
fields @timestamp, component, msg, reason
| filter component = "failover"
| sort @timestamp desc
```

Find all errors in the last hour:
```
fields @timestamp, component, msg
| filter level = "ERROR"
| sort @timestamp desc
| limit 50
```

Find peer heartbeat timeouts:
```
fields @timestamp, msg
| filter msg like /heartbeat timeout/
| sort @timestamp desc
```
