# Metrics

ZeroNAT exposes a Prometheus metrics endpoint on `:9100/metrics` (configurable
via the `metrics_addr` Terraform variable).

Scrape it like any Prometheus target:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: zeronat
    static_configs:
      - targets:
          - 10.0.1.10:9100   # node A
          - 10.0.2.10:9100   # node B
```

Or verify manually:
```bash
curl http://<nat-node-private-ip>:9100/metrics | grep zeronat_
```

All metrics carry an `instance_id` label (`i-XXXXXXXXXXXXXXXXX`) so you can
tell which node each metric came from.

---

## Connection metrics

| Metric | Type | Labels | Description |
|---|---|---|---|
| `zeronat_active_connections` | gauge | `instance_id` | Total active conntrack entries (TCP + UDP) |
| `zeronat_active_connections_by_ip` | gauge | `instance_id`, `src_ip` | Active connections per source IP in private subnets |
| `zeronat_tx_bytes_per_ip` | gauge | `instance_id`, `src_ip` | Bytes sent to the internet, per source IP |
| `zeronat_rx_bytes_per_ip` | gauge | `instance_id`, `src_ip` | Bytes received from the internet, per source IP |

`tx_bytes_per_ip` and `rx_bytes_per_ip` require conntrack byte accounting to be
enabled (`nf_conntrack_acct=1`). This is enabled by default in the ZeroNAT AMI.

**Example: find the top talkers by outbound traffic**
```promql
topk(10, zeronat_tx_bytes_per_ip)
```

**Example: alert when total active connections exceed a threshold**
```promql
zeronat_active_connections > 50000
```

---

## Interface metrics

Counters read from `/proc/net/dev`. Values are cumulative since the instance
started; use `rate()` in Prometheus for per-second throughput.

| Metric | Type | Labels | Description |
|---|---|---|---|
| `zeronat_interface_rx_bytes_total` | gauge | `instance_id`, `interface` | Total bytes received |
| `zeronat_interface_tx_bytes_total` | gauge | `instance_id`, `interface` | Total bytes transmitted |
| `zeronat_interface_rx_packets_total` | gauge | `instance_id`, `interface` | Total packets received |
| `zeronat_interface_tx_packets_total` | gauge | `instance_id`, `interface` | Total packets transmitted |
| `zeronat_interface_rx_errors_total` | gauge | `instance_id`, `interface` | Total receive errors |
| `zeronat_interface_tx_errors_total` | gauge | `instance_id`, `interface` | Total transmit errors |
| `zeronat_interface_rx_drops_total` | gauge | `instance_id`, `interface` | Total receive drops |
| `zeronat_interface_tx_drops_total` | gauge | `instance_id`, `interface` | Total transmit drops |

**Example: outbound throughput in Mbps on eth0**
```promql
rate(zeronat_interface_tx_bytes_total{interface="eth0"}[1m]) * 8 / 1e6
```

---

## System metrics

| Metric | Type | Labels | Description |
|---|---|---|---|
| `zeronat_cpu_usage_percent` | gauge | `instance_id` | Overall CPU utilisation (%) |
| `zeronat_cpu_iowait_percent` | gauge | `instance_id` | CPU time waiting for I/O (%) |
| `zeronat_cpu_irq_percent` | gauge | `instance_id` | CPU time servicing hardware interrupts (%) |
| `zeronat_cpu_softirq_percent` | gauge | `instance_id` | CPU time servicing software interrupts (%) |

High `softirq_percent` is normal on a busy NAT node — it reflects network
interrupt processing. Values above 50% at moderate throughput may indicate the
instance type is undersized.

---

## Collector health

| Metric | Type | Labels | Description |
|---|---|---|---|
| `zeronat_collection_errors_total` | counter | `instance_id` | Cumulative parse/read failures when collecting metrics |

A non-zero and increasing value here means the agent is having trouble reading
from `/proc`. Check disk space and file descriptor limits if this rises.

---

## Grafana dashboard

A pre-built Grafana dashboard is available in the
[ZeroNAT GitHub repository](https://github.com/zeronat-io/zeronat) under
`docker/grafana/dashboards/`. Import it via dashboard ID or JSON file.

The dashboard shows:
- Active connections over time (total and per-IP top talkers)
- Inbound/outbound throughput (Mbps)
- CPU usage and softirq load
- Interface error and drop rates
