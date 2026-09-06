circuit-mesh(1) "1.0.8" "circuit-mesh User Manual"

# NAME

circuit-mesh - Zero-Trust Network Engine with Zig, Netlink, and Tor

# SYNOPSIS

*circuit-mesh* [OPTIONS...]

# DESCRIPTION

*circuit-mesh* is a high-performance network security engine designed to enforce a
Zero-Trust egress policy. It operates by dynamically synchronizing the Linux
kernel's *IPSet* barrier via *Netlink* and tunneling DNS traffic through
isolated Tor circuits.

The engine ensures that system network access is restricted only to trusted nodes
(Tor Directory Authorities and Guards) while providing robust DNS-over-TLS (DoT)
and DNS-over-HTTPS (DoH) services with automated identity rotation.

# OPTIONS

*--config* <path>
	Path to the JSON configuration file. Defaults to
	*/etc/circuit-mesh/config.json*.

*--debug*
	Enable high-density telemetry. This provides real-time logs for Netlink
	barrier synchronization, Tor circuit status, and tunnel health metrics.

# CONFIGURATION (JSON)

The configuration file defines the behavior of the network barrier and encrypted
tunnels. Below are the primary top-level keys:

*ipset_name* (string)
	The name of the IPSet to be managed. *circuit-mesh* will automatically
	append '6' for IPv6 sets (e.g., "BOOTSTRAP" and "BOOTSTRAP6").

*monitoring_interval_ms* (integer)
	Frequency in milliseconds for the Netlink engine to verify Tor node
	availability.

*cold_start_doh_enabled* (boolean)
	If true, allows bootstrapping via direct DoH if Tor is not yet fully
	operational during startup.

*doh_fallback_allowed* (boolean)
	If true, allows a direct DoH connection as a secondary route if all Tor
	tunnels fail.

*global_settings*
	- *max_concurrent_rotations*: Max number of tunnels rotating identities
	  simultaneously.
	- *rotation_check_interval_s*: Internal health check frequency for
	  watchdogs.

*tor_global*
	Configuration for Tor interaction. Required for IP discovery and circuit
	purging.
	- *socks_ip*, *socks_port*: SOCKS5 listener for tunnels.
	- *control_ip*, *control_port*: Tor ControlPort access.
	- *cookie_path*: Path to Tor's *control_auth_cookie*.
	- *binary_path*: Path to Tor binary for hardcoded IP extraction.
	- *state_path*, *consensus_path*: Paths to Tor's internal state files
	  to resolve Guard node IPs.

*dns_tunnels* (array)
	Defines local DNS listeners.
	- *name*: Identifier for logging.
	- *ip*: Remote DNS server IP (e.g., "1.1.1.1").
	- *sni*: Server Name Indication for TLS/HTTPS.
	- *local_ip*, *local_port*: Local interface and port to listen on.

*rotation_profiles* (array)
	Defines TTL ranges for identities. A random jitter is applied between
	*min_ttl* and *max_ttl*.

# SECURITY

*circuit-mesh* requires *CAP_NET_ADMIN* and *CAP_NET_RAW* capabilities to
interact with the Netlink subsystem. It is recommended to run the binary as
*root* or via a systemd unit with appropriate ambient capabilities.

The *IPSet* barrier effectively blocks all traffic not explicitly allowed. Misconfiguration
of *tor_global* paths may lead to a total network lockout if the discovery phase
fails to find valid Tor entry points.

# FILES

*/etc/circuit-mesh/config.json*
	Default configuration file location.

# EXIT STATUS

*0*
	Success.

*1*
	Failure (e.g., Invalid configuration, insufficient permissions, or
	Netlink communication error).

# AUTHORS

Developed by TSUKUMO Akito <tsukumoakito99@duck.com>.

# LICENSE

Dual-licensed under the AGPL-3.0-or-later and a Commercial License.
