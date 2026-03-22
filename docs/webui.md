# Web UI

The ZeroNAT agent includes a built-in web dashboard. It starts automatically
with the daemon and gives a real-time view of cluster state, traffic, and logs
without requiring Prometheus or any external tooling.

---

## Accessing the Web UI

By default, the Web UI listens on `127.0.0.1:8080` — localhost only. It is not
reachable from the VPC until you change the listen address.

To allow access from within your VPC, set `web_addr` in the Terraform module:

```hcl
module "zeronat" {
  # ...
  web_addr = "0.0.0.0:8080"
}
```

Then open `http://<nat-node-private-ip>:8080` in your browser.

The security group created by the Terraform module allows inbound TCP 8080 from
`vpc_cidr` when that variable is set. If `vpc_cidr` is not set, add an inbound
rule manually.

---

## Authentication and TLS

When `web_addr` is set to a non-localhost address, **Basic Auth and TLS are
automatically enabled**. Without a password configured no auth is applied and it
serves plain HTTP — only expose it from localhost in that case.

To configure credentials, set `web_user` and `web_password` in the Terraform
module (or via the corresponding environment variables on the instance). When a
password is set:

- Basic Auth is required on all pages
- TLS is automatically enabled using a self-signed certificate generated at
  first startup (stored in `/run/zeronat/`)
- The browser will show a certificate warning for the self-signed cert — this
  is expected. To use your own certificate, set `web_tls_cert` and `web_tls_key`
  to paths on the instance.

Access with the self-signed cert:
```bash
# Bypass cert warning with curl
curl -k -u admin:<password> https://<nat-node-private-ip>:8080
```

---

## What the dashboard shows

### Dashboard (main page)

- **Cluster status**: node role (ACTIVE / STANDBY), peer IP, peer health,
  heartbeat age, EIP ownership
- **Route tables**: each managed route table, whether this node owns the route,
  and the current ENI target
- **Traffic**: total connections, packets/sec, bytes/sec, per-interface
  inbound/outbound throughput
- **Top talkers**: source IPs in private subnets ranked by active connections
  or outbound bytes
- **System**: CPU usage, softIRQ %, steal %, CPU credits remaining (T-series),
  memory and disk utilisation
- **Failover history**: recent role transitions with timestamps and reasons

### FQDN Filter page (`/fqdn-filter`)

Displays the current FQDN filter configuration and allows updating the allowlist
or denylist without restarting the agent. Changes take effect immediately for
new connections. See [fqdn-filtering.md](fqdn-filtering.md).

### Logs page (`/logs`)

Live-tailed log viewer for the `zeronat-agent` service,
directly in the browser. Useful for checking events without SSH access.

---

## Terminal dashboard (TUI)

If you are already SSH'd into a node, the agent also ships a terminal dashboard.
Run it from any shell on the instance:

```bash
zeronat-agent tui
```

The TUI connects to the running daemon over a local Unix socket — no network
required. It has four views, navigated with number keys or letters:

| Key | View |
|---|---|
| `1` or `d` | Dashboard (cluster state, interfaces, system) |
| `2` or `t` | Top talkers (connections and bandwidth per source IP) |
| `3` or `f` | Failover history |
| `4` or `c` | Configuration |
| `q` | Quit |

The display refreshes every second. It works over a slow SSH connection because
it renders directly in the terminal — no browser required.

---

## API endpoints

The Web UI exposes a small JSON API used by the dashboard's auto-refresh. These
are also useful for scripting:

| Endpoint | Method | Description |
|---|---|---|
| `/api/stats` | GET | Current traffic stats and system metrics |
| `/api/failover/history` | GET | Recent failover events |
| `/api/fqdn-config` | POST | Update FQDN filter configuration |
| `/api/logs/recent` | GET | Recent log lines from the agent |
| `/api/logs/stream` | GET | Server-sent event stream of live log output |

All endpoints require Basic Auth when authentication is enabled.
