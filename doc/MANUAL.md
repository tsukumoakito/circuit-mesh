<!--
SPDX-FileCopyrightText: 2026 TSUKUMO Akito <tsukumoakito99@duck.com>
SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-circuit-mesh-Commercial
-->

# Circuit Mesh Technical Manual (v1.0.1 / 2026-09-05)

`Circuit Mesh` is a Zero-Trust network gatekeeper. This document provides a granular explanation of its configuration schema, rotation logic, and implementation details.

---

## 1. Core Architecture

The engine operates on a state-machine basis:

1. **Bootstrapping**: Scans the filesystem to identify trusted IP addresses.
2. **Barrier Enforcement**: Updates the Linux kernel `IPSet` via Netlink.
3. **Encapsulation**: Intercepts local DNS traffic and tunnels it through Tor circuits.
4. **Identity Shifting**: Rotates SOCKS credentials to ensure egress IP diversity.

---

## 2. Configuration Reference (`config.json`)

### 2.1. Root Parameters

- **`ipset_name`** (String): The base name for the kernel IPSet.
    - *Mechanism*: `circuit-mesh` manages two sets. If set to `BOOTSTRAP`, it handles `BOOTSTRAP` (IPv4) and `BOOTSTRAP6` (IPv6).
- **`monitoring_interval_ms`** (Integer): The delay between Netlink synchronization loops.
- **`cold_start_doh_enabled`** (Boolean): If enabled, queries are sent via direct DoH (bypassing Tor) during the first 60 seconds if the Tor ControlPort is unreachable.
- **`doh_fallback_allowed`** (Boolean): If Tor connectivity is lost during runtime, the engine falls back to direct HTTPS tunneling to maintain system availability.

### 2.2. `tor_global` (Discovery Logic)

This section defines how the engine discovers "Trusted IPs" to populate the barrier.

- **`cookie_path`**: Path to the Tor `control_auth_cookie`. Required for ControlPort authentication.
- **`binary_path`**: The engine performs a binary scan of the Tor executable to extract hardcoded Directory Authority (DA) IP addresses (scanning for the `orport=` pattern).
- **`state_path`** / **`consensus_path`**: Scans Tor's internal descriptors to resolve the IP addresses of currently active Guard nodes.

### 2.3. `rotation_profiles` (Jitter Calculation)

Defines the lifecycle of a single Tor identity (SOCKS username/password pair).

- **Logic**: The Time-to-Live (TTL) is calculated using the following formula to prevent pattern analysis:
    `Next_Rotation = Current_Time + min_ttl + random(0, max_ttl - min_ttl)`
- **`name`**: Used to map profiles to services (e.g., "dns").

### 2.4. `dns_tunnels` (Tunnel Implementations)

Each entry spawns a local listener that wraps DNS queries into encrypted tunnels.

- **`sni`**: Crucial for TLS handshakes. Must match the certificate of the remote DNS provider.
- **Implementation Difference**:
    - **DoT (DNS over TLS)**: Uses **Zig Native TLS**. It is the primary high-performance route used when Tor is online.
    - **DoH (DNS over HTTPS)**: Uses **OpenSSL + Manual H2 Framing**. This is used for "Cold Start" and "Fallback" scenarios as it is more resilient to deep packet inspection (DPI) and proxy interference.

---

## 3. Implementation Details

### 3.1. Identity Rotation and Circuit Purging

When a rotation is triggered (either by TTL expiration or failure threshold):

1. A new random 64-character SOCKS5 username/password pair is generated.
2. A probe query is sent through the new identity.
3. Upon success, the old identity is flagged for purging.
4. `circuit-mesh` sends a `CLOSECIRCUIT` command to the Tor ControlPort for the specific `SOCKS_USERNAME` to ensure the old circuit is physically destroyed.

### 3.2. Netlink Engine

Unlike shell-script wrappers for `ipset`, `circuit-mesh` communicates directly with the kernel using raw Netlink sockets (`AF_NETLINK`).

- **Safety**: If the program crashes, the IPSet remains in the kernel, maintaining the lock.
- **Atomic Updates**: Uses `NLM_F_ACK` to ensure the kernel has successfully applied the barrier rules before proceeding.

---

## 4. Feature Roadmap

The following sections in `config.json` are currently defined in the schema but not yet fully implemented in the core logic:

- **`email_providers`**: Support for isolated IMAP/SMTP proxying with per-provider identity rotation.
- **`proxy_groups`**: Generic SOCKS/HTTP proxy chaining (e.g., I2P or VPN integration).
- **Zig 0.16.0 Migration**: Refactoring the codebase to support the upcoming Zig compiler release for improved build-time safety.

---

## 5. Deployment Example

```json
{
  "ipset_name": "TRUSTED_NODES",
  "dns_tunnels": [
    {
      "name": "Cloudflare-Tor",
      "ip": "1.1.1.1",
      "sni": "one.one.one.one",
      "local_ip": "127.0.0.1",
      "local_port": 5300
    }
  ],
  "rotation_profiles": [
    { "name": "dns", "min_ttl": 600, "max_ttl": 1200 }
  ]
}
```

*Note: Run `circuit-mesh --debug` to see the real-time calculation of these parameters in your terminal.*
