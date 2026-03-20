# FQDN Egress Filtering

ZeroNAT can restrict outbound traffic from private subnets by domain name.
This feature is **disabled by default**. When enabled, it applies to outbound
TCP traffic on port 80 (HTTP) and port 443 (HTTPS).

---

## How it works

All outbound traffic from private subnets passes through the ZeroNAT node.
When FQDN filtering is enabled, the node inspects the first data packet of each
new TCP connection:

- **HTTPS (port 443)**: reads the SNI field from the TLS ClientHello
- **HTTP (port 80)**: reads the `Host` header from the HTTP request line

The extracted hostname is checked against the configured list. The connection
is either allowed or dropped depending on the configured mode.

Subsequent packets of an already-decided connection are handled without
re-inspection (the decision is cached per connection).

All other traffic (UDP, non-80/443 TCP, ICMP) is not affected by FQDN
filtering. Those packets pass through normally regardless of the policy.

---

## Filter modes

### Allow mode (allowlist)

Only domains in the list are permitted. All other outbound HTTP/HTTPS traffic
is dropped.

Use this when you want to restrict egress to a known set of destinations:
package repositories, cloud APIs, internal services.

### Deny mode (denylist)

Domains in the list are blocked. All other outbound HTTP/HTTPS traffic passes.

Use this to block specific destinations (ad networks, data-exfiltration
endpoints) while leaving general internet access open.

**If the allowlist is empty, all traffic passes regardless of the denylist.**
This prevents accidentally blocking all traffic when no list has been
configured yet.

---

## Configuring via Terraform

```hcl
module "zeronat" {
  # ...

  fqdn_filter = {
    mode  = "allow"
    fqdns = [
      "api.github.com",
      "registry.npmjs.org",
      "pypi.org",
      "files.pythonhosted.org",
    ]
  }
}
```

For a denylist:
```hcl
fqdn_filter = {
  mode  = "deny"
  fqdns = [
    "malicious-domain.example.com",
    "data-exfil.example.net",
  ]
}
```

Changes to the FQDN list are applied without restarting the agent. The new
policy takes effect for new connections immediately; existing connections are
not interrupted.

---

## FQDN matching rules

- Matching is **case-insensitive**
- Matching is **exact** — `github.com` does not match `api.github.com`
- Wildcards are not supported in the current version

To allow both an apex domain and its subdomains, list both:
```json
["github.com", "api.github.com", "uploads.github.com"]
```

---

## Limitations

**HTTPS with ECH (Encrypted Client Hello)**: When a client uses TLS ECH, the
SNI is encrypted and the agent cannot extract the hostname. These connections are
allowed through (fail-open). This affects a small number of CDN endpoints that
have deployed ECH.

**HTTP CONNECT tunnels**: CONNECT-method proxied traffic is not inspected at the
tunnel level. The CONNECT destination hostname is visible, but traffic inside
the tunnel is not.

**Non-standard ports**: Only port 80 and 443 are inspected. If an application
uses HTTPS on a non-standard port, those connections bypass FQDN filtering.

**UDP (QUIC/HTTP3)**: Not inspected. QUIC traffic on port 443 passes through
regardless of the FQDN filter.

---

## Persistence

The FQDN list survives agent restarts. The policy is stored on disk and
re-applied at startup. If the agent crashes and restarts via systemd, the
filter is re-enabled with the same configuration.

---

## Checking filter decisions in logs

When FQDN filtering is active, the agent logs each filter decision:

```
FQDN_ALLOW  fqdn=api.github.com src=10.0.1.45:52312
FQDN_BLOCK  fqdn=example-blocked.com src=10.0.2.12:61904
```

To see filter activity in real time:
```bash
journalctl -u zeronat-agent -f | grep -E "FQDN_ALLOW|FQDN_BLOCK"
```
