<!--
SPDX-FileCopyrightText: 2026 TSUKUMO Akito <tsukumoakito99@duck.com>
SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-circuit-mesh-Commercial
-->

<p align="center">
  <img src="doc/circuit_mesh_logo.svg" width="100%" alt="Circuit Mesh Logo">
</p>

# Circuit Mesh (Zero-Trust Network Engine)

**A Zero-Trust Network Engine for Secure DNS Egress and Identity Rotation.**

`Circuit Mesh` is a high-performance network barrier and proxy manager written in Zig. It leverages Linux Netlink (IPSet) to dynamically control network access, forcing traffic through isolated Tor circuits with automated identity rotation and DoH/DoT fallback mechanisms.

The core command, `circuit-mesh`, operates as a gatekeeper, ensuring that your system's network egress remains within a strictly defined perimeter of trusted nodes.

[日本語版のREADMEはこちら (Japanese version available here)](./README_ja.md)

---

## Key Features

- **Dynamic Network Barrier**: Direct manipulation of Linux IPSet via Netlink to maintain a "Zero-Trust" perimeter. Only authenticated Tor nodes and designated DNS upstreams are permitted.
- **Hybrid DNS Tunneling**:
    - **DoT (DNS over TLS)**: Native Zig TLS implementation for high-efficiency tunneling over Tor.
    - **DoH (DNS over HTTPS)**: Integrated OpenSSL/H2 (HTTP/2) engine for robust fallback when native TLS is restricted.
- **Tor Identity Mastery**:
    - Automatic extraction of Directory Authorities (DA) and Guard nodes from Tor binaries and state files.
    - Per-tunnel SOCKS5 authentication rotation with seamless circuit purging via Tor ControlPort.
- **Success-Driven Rotation**: Logic-based identity switching triggered by TTL expiration or consecutive connection failures.
- **Memory Efficient**: Built with Zig’s manual memory management and custom tracking allocators for predictable resource usage in hardened environments.

---

## System Architecture

1. **Discovery Phase**: Scans Tor binary and consensus files to populate the initial "Safe IP" list.
2. **Netlink Barrier**: Synchronizes the kernel IPSet with the discovered IPs, effectively locking the network.
3. **DNS Service**: Listens on local UDP/TCP ports, wrapping queries into encrypted DoT/DoH tunnels.
4. **Watchdog**: Monitors tunnel health and rotates SOCKS credentials to ensure egress IP diversity.

---

## Technical Prerequisites

- **Zig Compiler**: `0.15.2` (Strictly enforced. Migration to 0.16.0 is planned).
- **Linux Kernel**: Must support `IPSet` and `Netlink`.
- **Dependencies**:
    - `OpenSSL`: Required for HTTP/2 (DoH) support.
    - `scdoc`: Required for generating man pages.
    - `Tor`: Must be running with `ControlPort` and `CookieAuthentication` enabled.

---

## Installation

### Arch Linux (via AUR)

Arch Linux users can install `circuit-mesh` from the AUR (Arch User Repository). This is the recommended method as it handles dependencies and systemd integration automatically according to Arch standards.

| Package | Version | Description | Votes | Links |
| :--- | :--- | :--- | :--- | :--- |
| **circuit-mesh** | ![AUR version](https://img.shields.io/aur/version/circuit-mesh) | Zero-Trust Network Engine | ![AUR votes](https://img.shields.io/aur/votes/circuit-mesh) | [![AUR](https://img.shields.io/badge/AUR-Package-orange)](https://aur.archlinux.org/packages/circuit-mesh) [![License](https://img.shields.io/aur/license/circuit-mesh)](./LICENSE) |

```bash
# Example using an AUR helper
yay -S circuit-mesh

# Using paru
paru -S circuit-mesh
```

### Other Linux Distributions (from Source)

For other distributions, you can build and install manually using the provided Makefile.

```bash
# Clone the repository
git clone https://codeberg.org/tsukumoakito/circuit-mesh.git
cd circuit-mesh

# 1. Build the binary
make build

# 2. Install to system (/usr/bin, /etc, etc.)
sudo make install

# 3. Uninstall from system
sudo make uninstall
```

---

## Execution

The `circuit-mesh` command requires root privileges (or `CAP_NET_ADMIN`) to manipulate the Netlink barrier.

```bash
# Run with high-density telemetry on Barrier sync and Tunnel health
sudo circuit-mesh --debug

# Run with a specific configuration path
sudo circuit-mesh --config /path/to/config.json
```

---

## Implementation Status & Roadmap

| Feature | Status | Description |
| :--- | :--- | :--- |
| **Netlink Engine** | ✅ Stable | IPSet manipulation for IPv4/IPv6. |
| **Tor Discovery** | ✅ Stable | Extraction from Binary/State/Consensus. |
| **DNS Tunnels** | ✅ Stable | DoT (Native) and DoH (OpenSSL/H2). |
| **Identity Rotation** | ✅ Stable | Credential rotation and Circuit Purging. |
| **Zig 0.16.0** | 🛠️ Planned | Migration to the latest compiler. |
| **Email Proxy** | 🛠️ Planned | IMAP/SMTP isolated proxying. |
| **Generic Proxies** | 🛠️ Planned | Support for I2P/VPN group chains. |

---

## Documentation

- **MANUAL.md**: Detailed JSON configuration schema and rotation logic.
- **man circuit-mesh(1)**: Standard Unix manual page (English/Japanese).
- **COMMERCIAL.md**: Licensing terms for corporate integration.

---

## License

Dual-licensed under:

- **GNU Affero General Public License v3.0 or later (AGPL-3.0-or-later)**
- **Commercial License** (See `doc/COMMERCIAL.md` for details)

---
**Developer Note**: This project is currently in an experimental beta state. Use with caution in production environments requiring high availability.
