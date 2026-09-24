#!/usr/bin/env bash
#------------------------------------------------------------------------------
# cloudflared-container-setup.sh
# Setup environment on Alma Linux 9 server to run rootless container for
#  CloudflareD tunnel daemon.
#
# Vibe coded with Cloude Sonet 4.6 on July 27, 2026.
#   -- https://www.perplexity.ai/search/914c5f0b-13c3-4605-a520-7f495d7792b9
#
# Implements:
#  1) Install packages: podman, passt
#  2) Prompt once for a base username (default: cloudflared). The prod
#     instance always runs as "<base>-prod" (created if missing):
#      a) cloudflared image tag
#      b) cloudflared tunnel token (dashboard-generated)
#  3) OPTIONAL: prompt to also install a second "dev" instance, which
#     always runs as "<base>-dev" (a distinct account from prod):
#      a) cloudflared image tag
#      b) cloudflared tunnel token
# 3b) Prompt once (shared by both prod and dev) for the network interface
#     to bind outgoing Cloudflare Edge connections to. The interface's
#     IPv4 address is written as TUNNEL_EDGE_BIND_ADDRESS; TUNNEL_EDGE_IP_VERSION
#     is always hardcoded to "4" (no prompt). Both env vars are written
#     into each instance's 40-image[-dev].conf drop-in, using the same
#     values for prod and dev.
#  4) Enable persistent journaling + per-user journals
#  5) Enable boot-start for user services (linger) for each instance's user
#  6) Write /etc/sysctl.d/99-cloudflared.conf to update system limits for ping users and udp socket buffers
#  7) Pull cloudflared image (fully-qualified docker.io/cloudflare/cloudflared:<tag>) per instance
#  8) Create Quadlet base + drop-ins per instance:
#      - prod unit: cloudflared.service (container file: cloudflared.container), user "<base>-prod"
#      - dev unit:  cloudflared-dev.service (container file: cloudflared-dev.container), user "<base>-dev"
#      - dev drop-in files are suffixed "-dev" to keep them unambiguous
#  9) Start each instance's systemd --user service
# 10) Install a single merged /usr/local/sbin/cloudflared-container
#     management command (menu-driven status/restart/upgrade tool; usable
#     by any sudoer). It prompts for the base username and prod/dev
#     instance at startup, and again from its "switch" menu item.
# 11) Write /etc/profile.d/cloudflare-alias.sh (aliases for both instances,
#     if dev was installed)
#
# Notes:
#  - Token is stored on disk in a drop-in file (0600). Protect the user account.
#  - Rootless systemd user services require a working user runtime dir; the script
#    sets XDG_RUNTIME_DIR to avoid "Failed to connect to bus: No medium found".
#  - The "prod" and "dev" instances always run under distinct rootless
#    users, "<base>-prod" and "<base>-dev", derived from one base username.
#  - TUNNEL_EDGE_IP_VERSION/TUNNEL_EDGE_BIND_ADDRESS are set once from a
#    single interface selection and shared by both instances; the
#    management command's upgrade action preserves them across image
#    tag changes instead of resetting the drop-in file.
#
# Usage:
#   sudo bash cloudflared-container-setup.sh
#------------------------------------------------------------------------------

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*" >&2; }
warn() { echo "WARN: $*" >&2; }

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash $0"; }

iface_exists() { ip link show dev "$1" >/dev/null 2>&1; }

# Print the first IPv4 address (no CIDR suffix) assigned to the given
# interface, or return non-zero if none is found.
iface_ipv4_address() {
  local iface="$1"
  ip -4 -o addr show dev "$iface" scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | head -n1
}

# Print the interface currently holding the default (0.0.0.0/0) IPv4
# route, or nothing if there isn't one.
default_route_iface() {
  ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1
}

# Print the gateway of the default IPv4 route on the given interface, or
# nothing if that interface has no default route.
default_route_gateway_on_iface() {
  local iface="$1"
  ip -4 route show default dev "$iface" 2>/dev/null \
    | awk '{for (i=1;i<=NF;i++) if ($i=="via") print $(i+1)}' | head -n1
}

# Print the NetworkManager connection name that currently owns the given
# interface, or nothing if NetworkManager doesn't manage it (or isn't
# running).
nm_connection_for_iface() {
  local iface="$1"
  command -v nmcli >/dev/null 2>&1 || return 0
  nmcli -t -f DEVICE,CONNECTION device status 2>/dev/null \
    | awk -F: -v d="$iface" '$1==d {print $2; exit}'
}

# Print every distinct IPv4 address a hostname resolves to (one per
# line), or nothing on failure. Uses getent (NSS-aware: honours
# /etc/hosts and nsswitch.conf, same resolution path applications use)
# rather than dig, since dig/bind-utils may not be installed.
resolve_ipv4_addresses() {
  local host="$1"
  # getent exits non-zero when a hostname has no A/AAAA record (e.g.
  # cfd-features.argotunnel.com, which is resolved elsewhere as a TXT
  # record). Under `set -o pipefail`, that non-zero status would
  # otherwise propagate out of this pipeline and -- because callers
  # capture this function's output via command substitution with no
  # `|| true` guard of their own -- kill the whole script under
  # `set -e` before they ever get a chance to check for an empty
  # result. The `|| true` neutralizes that; callers already treat
  # empty output as "could not resolve" and warn/skip accordingly.
  getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u || true
}

# Static IPv4 CIDR ranges covering Cloudflare's documented Tunnel edge
# addresses (region1.v2.argotunnel.com / region2.v2.argotunnel.com,
# TCP/UDP port 7844), for the default (non-US, non-FedRAMP) region. See:
# https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/
readonly CLOUDFLARE_TUNNEL_EDGE_PREFIXES=("198.41.192.0/24" "198.41.200.0/24")

# Hostnames cloudflared also talks to that should be routed the same
# way as the tunnel edge itself: api.cloudflare.com (software update
# checks) and cfd-features.argotunnel.com (QUIC datagram version
# negotiation, resolved as a DNS TXT lookup but the A/AAAA lookup of
# the same name is what actually gets routed here). See:
# https://developers.cloudflare.com/tunnel/configuration/
readonly CLOUDFLARE_TUNNEL_EDGE_HOSTNAMES=("api.cloudflare.com" "cfd-features.argotunnel.com")

# Fixed IPv4 host addresses (Cloudflare's public DNS resolver) to route
# the same way as the tunnel edge.
readonly CLOUDFLARE_TUNNEL_EDGE_HOSTS=("1.1.1.1" "1.0.0.1")

# Route Cloudflare Tunnel's edge ranges, the resolved addresses of
# api.cloudflare.com / cfd-features.argotunnel.com, and 1.1.1.1/1.0.0.1
# out the edge interface (e.g. eth1), via that interface's own gateway.
# Also marks the edge connection ipv4.never-default so NetworkManager
# never assigns it the default route (belt-and-suspenders on top of the
# static routes: the default route and every other destination --
# general internet egress, RFC 1918 ranges, etc. -- stay on the primary
# interface, normally eth0, untouched).
#
# Applied via NetworkManager (nmcli) so changes survive reboots. Uses
# "nmcli device reapply" rather than "connection up" so changes take
# effect without a full connection bounce.
#
# Idempotent and safe to re-run: re-running the setup script, or the
# "Refresh Cloudflare edge routes" management-tool action, picks up any
# newly-resolved IPs for the hostnames above without disturbing routes
# that are already present.
configure_edge_routing() {
  local edge_iface="$1"

  command -v nmcli >/dev/null 2>&1 || {
    warn "nmcli not found; skipping Cloudflare Tunnel edge static routes for ${edge_iface}."
    return 0
  }

  local primary_iface
  primary_iface="$(default_route_iface)"
  if [[ -z "$primary_iface" ]]; then
    warn "Could not determine the interface currently holding the default route; skipping Cloudflare Tunnel edge static routes."
    return 0
  fi
  if [[ "$primary_iface" == "$edge_iface" ]]; then
    info "${edge_iface} already holds the default route; no separate routing needed for Cloudflare Tunnel edge ranges, skipping."
    return 0
  fi

  local edge_gateway
  edge_gateway="$(default_route_gateway_on_iface "$edge_iface")"
  if [[ -z "$edge_gateway" ]]; then
    warn "Could not determine a gateway on ${edge_iface} (no default route present on it); skipping Cloudflare Tunnel edge static routes."
    return 0
  fi

  local edge_conn
  edge_conn="$(nm_connection_for_iface "$edge_iface")"
  if [[ -z "$edge_conn" ]]; then
    warn "Could not resolve a NetworkManager connection for ${edge_iface}; skipping Cloudflare Tunnel edge static routes."
    return 0
  fi

  # Build the full list of host routes (CIDR prefixes) to add: the
  # fixed Cloudflare Tunnel edge /24s, the fixed 1.1.1.1/1.0.0.1 hosts,
  # and whatever api.cloudflare.com / cfd-features.argotunnel.com
  # currently resolve to (as /32s). Resolution failures are warned
  # about but do not abort the rest of the routing setup.
  local edge_prefixes=("${CLOUDFLARE_TUNNEL_EDGE_PREFIXES[@]}")
  local host_ip
  for host_ip in "${CLOUDFLARE_TUNNEL_EDGE_HOSTS[@]}"; do
    edge_prefixes+=("${host_ip}/32")
  done

  local hostname resolved_ips ip
  for hostname in "${CLOUDFLARE_TUNNEL_EDGE_HOSTNAMES[@]}"; do
    resolved_ips="$(resolve_ipv4_addresses "$hostname")"
    if [[ -z "$resolved_ips" ]]; then
      warn "Could not resolve ${hostname} to an IPv4 address; skipping its route for now."
      continue
    fi
    while IFS= read -r ip; do
      [[ -n "$ip" ]] && edge_prefixes+=("${ip}/32")
    done <<<"$resolved_ips"
  done

  echo
  info "Planned network changes so this host reaches Cloudflare Tunnel edge servers via ${edge_iface}, while everything else (including the public internet and RFC 1918 destinations) keeps using ${primary_iface} unchanged:"
  info "  - Add static routes via ${edge_gateway} on '${edge_conn}' (${edge_iface}) for: ${edge_prefixes[*]}"
  info "  - Set ipv4.never-default=yes on '${edge_conn}' (${edge_iface}) so NetworkManager never assigns it the default route"
  read -r -p "Apply these network changes now? [y/N]: " confirm_routing
  if [[ "${confirm_routing,,}" != "y" ]]; then
    warn "Skipping Cloudflare Tunnel edge routing changes at your request."
    return 0
  fi

  local existing_routes prefix route_changed=0
  existing_routes="$(nmcli -t -g ipv4.routes connection show "$edge_conn" 2>/dev/null)"
  for prefix in "${edge_prefixes[@]}"; do
    if [[ "$existing_routes" == *"${prefix}"* ]]; then
      info "Route for ${prefix} already present on '${edge_conn}', leaving as-is."
      continue
    fi
    info "Adding route ${prefix} via ${edge_gateway} to '${edge_conn}'"
    nmcli connection modify "$edge_conn" +ipv4.routes "${prefix} ${edge_gateway}" \
      || { warn "Failed to add route ${prefix} to '${edge_conn}'"; continue; }
    route_changed=1
  done

  local current_never_default
  current_never_default="$(nmcli -t -g ipv4.never-default connection show "$edge_conn" 2>/dev/null)"
  if [[ "${current_never_default,,}" != "yes" ]]; then
    info "Setting ipv4.never-default=yes on '${edge_conn}' (${edge_iface})"
    nmcli connection modify "$edge_conn" ipv4.never-default yes \
      || { warn "Failed to set ipv4.never-default on '${edge_conn}'"; }
    route_changed=1
  else
    info "ipv4.never-default already set on '${edge_conn}', leaving as-is."
  fi

  if [[ "$route_changed" == "1" ]]; then
    nmcli device reapply "$edge_iface" \
      || warn "Failed to reapply '${edge_conn}' on ${edge_iface}; changes are saved but may need 'nmcli connection up ${edge_conn}' (or a reboot) to take effect."
  fi

  echo
  info "Resulting IPv4 routing table:"
  ip -4 route show >&2
}

user_exists() { id "$1" >/dev/null 2>&1; }

ensure_user() {
  local u="$1"
  if user_exists "$u"; then
    info "User exists: $u"
  else
    info "User does not exist, creating: $u"
    useradd -m -s /bin/bash "$u"
  fi
  ensure_subuid_subgid "$u"
}

user_uid() { id -u "$1"; }

# Ensure a user has subuid/subgid ranges allocated for rootless Podman.
# Handles both newly created and pre-existing users. useradd normally
# allocates these automatically via /etc/login.defs for new accounts, but
# pre-existing accounts (the user_exists branch above) are never verified,
# which can cause confusing rootless Podman failures later.
ensure_subuid_subgid() {
  local u="$1"
  local need_subuid=1 need_subgid=1

  grep -Eq "^${u}:" /etc/subuid 2>/dev/null && need_subuid=0
  grep -Eq "^${u}:" /etc/subgid 2>/dev/null && need_subgid=0

  if [[ "$need_subuid" -eq 0 && "$need_subgid" -eq 0 ]]; then
    info "subuid/subgid already allocated for user: $u"
    return 0
  fi

  info "Allocating missing subuid/subgid range(s) for user: $u"
  if command -v usermod >/dev/null 2>&1; then
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$u" 2>/dev/null || true
  fi

  grep -Eq "^${u}:" /etc/subuid 2>/dev/null || echo "${u}:100000:65536" >> /etc/subuid
  grep -Eq "^${u}:" /etc/subgid 2>/dev/null || echo "${u}:100000:65536" >> /etc/subgid

  grep -Eq "^${u}:" /etc/subuid 2>/dev/null || die "Failed to allocate subuid range for user: $u"
  grep -Eq "^${u}:" /etc/subgid 2>/dev/null || die "Failed to allocate subgid range for user: $u"

  info "subuid/subgid ranges confirmed for user: $u (run 'podman system migrate' as $u if the service already ran before this change)"
}

# Run systemctl --user for a given user in non-interactive contexts.
user_systemctl() {
  local u="$1"; shift
  local uid; uid="$(user_uid "$u")"

  mkdir -p "/run/user/${uid}"
  chown "${uid}:${uid}" "/run/user/${uid}"
  chmod 0700 "/run/user/${uid}"

  sudo -u "$u" env XDG_RUNTIME_DIR="/run/user/${uid}" systemctl --user "$@"
}

install_packages() {
  info "Installing packages: podman, passt"
  dnf install -y podman passt >/dev/null
}

enable_persistent_journaling() {
  info "Enabling persistent journaling and per-user journals (SplitMode=uid)"

  mkdir -p /var/log/journal
  chmod 2755 /var/log/journal

  mkdir -p /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/99-persistent.conf <<'EOF'
[Journal]
Storage=persistent
SplitMode=uid
EOF

  systemctl restart systemd-journald.service
  journalctl --flush >/dev/null 2>&1 || true
}

enable_linger_for_user() {
  local u="$1"
  info "Enabling linger (boot-start for systemd --user) for user: $u"
  loginctl enable-linger "$u"
}

write_sysctl_cloudflared() {
  info "Writing /etc/sysctl.d/99-cloudflared.conf"

  cat >/etc/sysctl.d/99-cloudflared.conf <<'EOF'
# Cloudflared ICMP proxy enablement and QUIC UDP socket buffer ceilings.

# Allow the cloudflared container's nonroot group (65532) to create ICMP echo sockets.
net.ipv4.ping_group_range = 0 65532
net.ipv6.ping_group_range = 0 65532

# QUIC UDP socket buffer ceilings (helps avoid quic-go UDP buffer warnings).
net.core.rmem_max = 12000000
net.core.wmem_max = 12000000
EOF

  sysctl --system >/dev/null
}

pull_cloudflared_image_rootless() {
  local u="$1" tag="$2"
  local homedir
  homedir="$(getent passwd "$u" | awk -F: '{print $6}')"
  [[ -n "$homedir" && -d "$homedir" ]] || die "Could not determine home directory for user: $u"

  info "Pulling image as rootless user $u: docker.io/cloudflare/cloudflared:${tag}"
  sudo -H -u "$u" bash -lc "cd '$homedir' && podman pull 'docker.io/cloudflare/cloudflared:${tag}'"
}

# Install the single merged management command, which prompts for a base
# username and prod/dev instance selection at runtime (and again whenever
# you use the "switch user/instance" menu item), rather than being baked
# to one fixed instance at install time.
# Installs to: /usr/local/sbin/cloudflared-container
install_management_command() {
  local install_path="/usr/local/sbin/cloudflared-container"

  info "Installing cloudflared-container management command to: ${install_path}"

  cat >"${install_path}" <<'MANAGE_SCRIPT_EOF'
#!/usr/bin/env bash
#------------------------------------------------------------------------------
# cloudflared-container
# Menu-driven management tool for rootless cloudflared Podman Quadlet
# deployments created by cloudflared-container-setup.sh.
#
# Manages either the "prod" or "dev" instance, selected at runtime:
#   - prod: user "<base>-prod", unit cloudflared.service
#   - dev:  user "<base>-dev",  unit cloudflared-dev.service
#
# Must be run with sudo/root. Internally switches to the instance user's
# systemd --user session via XDG_RUNTIME_DIR so any sudoer can manage the
# container without needing to log in as that user directly.
#
# Usage:
#   sudo cloudflared-container
#------------------------------------------------------------------------------

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*" >&2; }
warn() { echo "WARN: $*" >&2; }

require_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo cloudflared-container"; }

user_exists() { id "$1" >/dev/null 2>&1; }

user_uid() { id -u "$1"; }

user_home() { getent passwd "$1" | awk -F: '{print $6}'; }

iface_exists() { ip link show dev "$1" >/dev/null 2>&1; }

# Print the first IPv4 address (no CIDR suffix) assigned to the given
# interface, or return non-zero if none is found.
iface_ipv4_address() {
  local iface="$1"
  ip -4 -o addr show dev "$iface" scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | head -n1
}

# Print the interface that currently owns the given IPv4 address, or
# nothing if no interface has it.
iface_for_ipv4_address() {
  local addr="$1"
  ip -4 -o addr show scope global 2>/dev/null \
    | awk -v a="$addr" '{split($4,parts,"/"); if (parts[1]==a) {print $2; exit}}'
}

# Print the interface currently holding the default (0.0.0.0/0) IPv4
# route, or nothing if there isn't one.
default_route_iface() {
  ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1
}

# Print the gateway of the default IPv4 route on the given interface, or
# nothing if that interface has no default route.
default_route_gateway_on_iface() {
  local iface="$1"
  ip -4 route show default dev "$iface" 2>/dev/null \
    | awk '{for (i=1;i<=NF;i++) if ($i=="via") print $(i+1)}' | head -n1
}

# Print the NetworkManager connection name that currently owns the given
# interface, or nothing if NetworkManager doesn't manage it (or isn't
# running).
nm_connection_for_iface() {
  local iface="$1"
  command -v nmcli >/dev/null 2>&1 || return 0
  nmcli -t -f DEVICE,CONNECTION device status 2>/dev/null \
    | awk -F: -v d="$iface" '$1==d {print $2; exit}'
}

# Print every distinct IPv4 address a hostname resolves to (one per
# line), or nothing on failure. Uses getent (NSS-aware: honours
# /etc/hosts and nsswitch.conf, same resolution path applications use)
# rather than dig, since dig/bind-utils may not be installed.
resolve_ipv4_addresses() {
  local host="$1"
  # getent exits non-zero when a hostname has no A/AAAA record (e.g.
  # cfd-features.argotunnel.com, which is resolved elsewhere as a TXT
  # record). Under `set -o pipefail`, that non-zero status would
  # otherwise propagate out of this pipeline and -- because callers
  # capture this function's output via command substitution with no
  # `|| true` guard of their own -- kill the whole script under
  # `set -e` before they ever get a chance to check for an empty
  # result. The `|| true` neutralizes that; callers already treat
  # empty output as "could not resolve" and warn/skip accordingly.
  getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u || true
}

# Static IPv4 CIDR ranges covering Cloudflare's documented Tunnel edge
# addresses (region1.v2.argotunnel.com / region2.v2.argotunnel.com,
# TCP/UDP port 7844), for the default (non-US, non-FedRAMP) region. See:
# https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/
readonly CLOUDFLARE_TUNNEL_EDGE_PREFIXES=("198.41.192.0/24" "198.41.200.0/24")

# Hostnames cloudflared also talks to that should be routed the same
# way as the tunnel edge itself: api.cloudflare.com (software update
# checks) and cfd-features.argotunnel.com (QUIC datagram version
# negotiation, resolved as a DNS TXT lookup but the A/AAAA lookup of
# the same name is what actually gets routed here). See:
# https://developers.cloudflare.com/tunnel/configuration/
readonly CLOUDFLARE_TUNNEL_EDGE_HOSTNAMES=("api.cloudflare.com" "cfd-features.argotunnel.com")

# Fixed IPv4 host addresses (Cloudflare's public DNS resolver) to route
# the same way as the tunnel edge.
readonly CLOUDFLARE_TUNNEL_EDGE_HOSTS=("1.1.1.1" "1.0.0.1")

# Route Cloudflare Tunnel's edge ranges, the resolved addresses of
# api.cloudflare.com / cfd-features.argotunnel.com, and 1.1.1.1/1.0.0.1
# out the edge interface (e.g. eth1), via that interface's own gateway.
# Also marks the edge connection ipv4.never-default so NetworkManager
# never assigns it the default route (belt-and-suspenders on top of the
# static routes: the default route and every other destination --
# general internet egress, RFC 1918 ranges, etc. -- stay on the primary
# interface, normally eth0, untouched).
#
# Applied via NetworkManager (nmcli) so changes survive reboots. Uses
# "nmcli device reapply" rather than "connection up" so changes take
# effect without a full connection bounce.
#
# Idempotent and safe to re-run: re-running the setup script, or the
# "Refresh Cloudflare edge routes" management-tool action, picks up any
# newly-resolved IPs for the hostnames above without disturbing routes
# that are already present.
configure_edge_routing() {
  local edge_iface="$1"

  command -v nmcli >/dev/null 2>&1 || {
    warn "nmcli not found; skipping Cloudflare Tunnel edge static routes for ${edge_iface}."
    return 0
  }

  local primary_iface
  primary_iface="$(default_route_iface)"
  if [[ -z "$primary_iface" ]]; then
    warn "Could not determine the interface currently holding the default route; skipping Cloudflare Tunnel edge static routes."
    return 0
  fi
  if [[ "$primary_iface" == "$edge_iface" ]]; then
    info "${edge_iface} already holds the default route; no separate routing needed for Cloudflare Tunnel edge ranges, skipping."
    return 0
  fi

  local edge_gateway
  edge_gateway="$(default_route_gateway_on_iface "$edge_iface")"
  if [[ -z "$edge_gateway" ]]; then
    warn "Could not determine a gateway on ${edge_iface} (no default route present on it); skipping Cloudflare Tunnel edge static routes."
    return 0
  fi

  local edge_conn
  edge_conn="$(nm_connection_for_iface "$edge_iface")"
  if [[ -z "$edge_conn" ]]; then
    warn "Could not resolve a NetworkManager connection for ${edge_iface}; skipping Cloudflare Tunnel edge static routes."
    return 0
  fi

  # Build the full list of host routes (CIDR prefixes) to add: the
  # fixed Cloudflare Tunnel edge /24s, the fixed 1.1.1.1/1.0.0.1 hosts,
  # and whatever api.cloudflare.com / cfd-features.argotunnel.com
  # currently resolve to (as /32s). Resolution failures are warned
  # about but do not abort the rest of the routing setup.
  local edge_prefixes=("${CLOUDFLARE_TUNNEL_EDGE_PREFIXES[@]}")
  local host_ip
  for host_ip in "${CLOUDFLARE_TUNNEL_EDGE_HOSTS[@]}"; do
    edge_prefixes+=("${host_ip}/32")
  done

  local hostname resolved_ips ip
  for hostname in "${CLOUDFLARE_TUNNEL_EDGE_HOSTNAMES[@]}"; do
    resolved_ips="$(resolve_ipv4_addresses "$hostname")"
    if [[ -z "$resolved_ips" ]]; then
      warn "Could not resolve ${hostname} to an IPv4 address; skipping its route for now."
      continue
    fi
    while IFS= read -r ip; do
      [[ -n "$ip" ]] && edge_prefixes+=("${ip}/32")
    done <<<"$resolved_ips"
  done

  echo
  info "Planned network changes so this host reaches Cloudflare Tunnel edge servers via ${edge_iface}, while everything else (including the public internet and RFC 1918 destinations) keeps using ${primary_iface} unchanged:"
  info "  - Add static routes via ${edge_gateway} on '${edge_conn}' (${edge_iface}) for: ${edge_prefixes[*]}"
  info "  - Set ipv4.never-default=yes on '${edge_conn}' (${edge_iface}) so NetworkManager never assigns it the default route"
  read -r -p "Apply these network changes now? [y/N]: " confirm_routing
  if [[ "${confirm_routing,,}" != "y" ]]; then
    warn "Skipping Cloudflare Tunnel edge routing changes at your request."
    return 0
  fi

  local existing_routes prefix route_changed=0
  existing_routes="$(nmcli -t -g ipv4.routes connection show "$edge_conn" 2>/dev/null)"
  for prefix in "${edge_prefixes[@]}"; do
    if [[ "$existing_routes" == *"${prefix}"* ]]; then
      info "Route for ${prefix} already present on '${edge_conn}', leaving as-is."
      continue
    fi
    info "Adding route ${prefix} via ${edge_gateway} to '${edge_conn}'"
    nmcli connection modify "$edge_conn" +ipv4.routes "${prefix} ${edge_gateway}" \
      || { warn "Failed to add route ${prefix} to '${edge_conn}'"; continue; }
    route_changed=1
  done

  local current_never_default
  current_never_default="$(nmcli -t -g ipv4.never-default connection show "$edge_conn" 2>/dev/null)"
  if [[ "${current_never_default,,}" != "yes" ]]; then
    info "Setting ipv4.never-default=yes on '${edge_conn}' (${edge_iface})"
    nmcli connection modify "$edge_conn" ipv4.never-default yes \
      || { warn "Failed to set ipv4.never-default on '${edge_conn}'"; }
    route_changed=1
  else
    info "ipv4.never-default already set on '${edge_conn}', leaving as-is."
  fi

  if [[ "$route_changed" == "1" ]]; then
    nmcli device reapply "$edge_iface" \
      || warn "Failed to reapply '${edge_conn}' on ${edge_iface}; changes are saved but may need 'nmcli connection up ${edge_conn}' (or a reboot) to take effect."
  fi

  echo
  info "Resulting IPv4 routing table:"
  ip -4 route show >&2
}

# Recover the edge interface name for the current instance from its
# Quadlet .container file (written by create_quadlet_rootless() as
# "Network=pasta:-i,<iface>"), without re-prompting the operator.
edge_iface_from_container_file() {
  [[ -f "$CONTAINER_FILE" ]] || { warn "Container unit not found: ${CONTAINER_FILE}"; return 1; }
  local iface
  # grep -Eo exits non-zero when the pattern isn't found. Under
  # `set -o pipefail` that would otherwise kill this assignment (and,
  # without a guard at the call site, the whole script) before the
  # empty-check below ever runs -- add `|| true` so a genuine "not
  # found" is reported by that check instead of a silent script exit.
  iface="$(grep -Eo 'pasta:-i,[^[:space:]]+' "$CONTAINER_FILE" 2>/dev/null | sed -E 's/^pasta:-i,//' | head -n1 || true)"
  if [[ -z "$iface" ]]; then
    warn "Could not determine the edge interface from ${CONTAINER_FILE} (no 'pasta:-i,<iface>' network line found)."
    return 1
  fi
  echo "$iface"
}

# Run systemctl --user for a given user, setting XDG_RUNTIME_DIR so that
# any sudo-privileged caller (not just the instance user itself) can
# reach that user's systemd --user session and manage the container.
user_systemctl() {
  local u="$1"; shift
  local uid; uid="$(user_uid "$u")"
  local runtime_dir="/run/user/${uid}"

  if [[ ! -d "$runtime_dir" ]]; then
    mkdir -p "$runtime_dir"
    chown "${uid}:${uid}" "$runtime_dir"
    chmod 0700 "$runtime_dir"
  fi

  sudo -u "$u" env XDG_RUNTIME_DIR="$runtime_dir" systemctl --user "$@"
}

# Run an arbitrary command as the instance user with XDG_RUNTIME_DIR set,
# e.g. for podman commands that talk to the user's rootless Podman socket.
user_run() {
  local u="$1"; shift
  local uid; uid="$(user_uid "$u")"
  local runtime_dir="/run/user/${uid}"
  local homedir; homedir="$(user_home "$u")"

  if [[ ! -d "$runtime_dir" ]]; then
    mkdir -p "$runtime_dir"
    chown "${uid}:${uid}" "$runtime_dir"
    chmod 0700 "$runtime_dir"
  fi

  sudo -H -u "$u" env XDG_RUNTIME_DIR="$runtime_dir" bash -lc "cd '$homedir' && $*"
}

# Try to auto-detect a sensible default base username by scanning for any
# existing "<base>-prod" or "<base>-dev" account with a Quadlet container
# file already in place. Falls back to "cloudflared" if nothing is found.
detect_base_user() {
  local pw_home pw_user

  for pw_home in $(getent passwd | awk -F: '{print $6}'); do
    pw_user="$(getent passwd | awk -F: -v h="$pw_home" '$6==h {print $1; exit}')"
    [[ -n "$pw_user" ]] || continue

    if [[ "$pw_user" == *-prod && -f "${pw_home}/.config/containers/systemd/cloudflared.container" ]]; then
      echo "${pw_user%-prod}"
      return 0
    fi
    if [[ "$pw_user" == *-dev && -f "${pw_home}/.config/containers/systemd/cloudflared-dev.container" ]]; then
      echo "${pw_user%-dev}"
      return 0
    fi
  done

  echo "cloudflared"
  return 0
}

# Prompt for the base username and prod/dev instance, then resolve the
# concrete user + unit/container names + Quadlet file paths for it.
# Called at startup and again from the "switch user/instance" menu item.
resolve_instance() {
  local detected_base
  detected_base="$(detect_base_user)"

  read -r -p "Base username for cloudflared [${detected_base}]: " BASE_USER
  BASE_USER="${BASE_USER:-$detected_base}"

  local inst_choice=""
  while [[ "$inst_choice" != "prod" && "$inst_choice" != "dev" ]]; do
    read -r -p "Manage which instance? [prod/dev] (default: prod): " inst_choice
    inst_choice="${inst_choice:-prod}"
    inst_choice="${inst_choice,,}"
    [[ "$inst_choice" == "prod" || "$inst_choice" == "dev" ]] || warn "Please enter 'prod' or 'dev'"
  done
  INSTANCE="$inst_choice"

  if [[ "$INSTANCE" == "prod" ]]; then
    CF_USER="${BASE_USER}-prod"
    UNIT_BASE="cloudflared"
    CONTAINER_NAME="cloudflared"
    IMAGE_DROPIN_NAME="40-image.conf"
    TOKEN_ENV_NAME="cloudflared.env"
  else
    CF_USER="${BASE_USER}-dev"
    UNIT_BASE="cloudflared-dev"
    CONTAINER_NAME="cloudflared-dev"
    IMAGE_DROPIN_NAME="40-image-dev.conf"
    TOKEN_ENV_NAME="cloudflared-dev.env"
  fi

  user_exists "$CF_USER" || die "User '${CF_USER}' does not exist on this system"

  QUADLET_DIR="$(user_home "$CF_USER")/.config/containers/systemd"
  DROPIN_DIR="${QUADLET_DIR}/${UNIT_BASE}.container.d"
  IMAGE_DROPIN="${DROPIN_DIR}/${IMAGE_DROPIN_NAME}"
  TOKEN_ENV_FILE="${DROPIN_DIR}/${TOKEN_ENV_NAME}"
  CONTAINER_FILE="${QUADLET_DIR}/${UNIT_BASE}.container"

  [[ -d "$QUADLET_DIR" ]] || die "Quadlet directory not found for ${CF_USER}: ${QUADLET_DIR}"
}

#------------------------------------------------------------------------------
# 1) Show cloudflared container status
#------------------------------------------------------------------------------
action_status() {
  echo
  info "== podman status (as user: ${CF_USER}) =="
  user_run "$CF_USER" "podman ps -a --filter name=${CONTAINER_NAME}" || warn "Failed to list podman containers"

  echo
  user_run "$CF_USER" "podman inspect ${CONTAINER_NAME} --format 'State: {{.State.Status}}  |  Started: {{.State.StartedAt}}  |  Image: {{.Config.Image}}'" 2>/dev/null || \
    warn "Could not inspect '${CONTAINER_NAME}' container (it may not be running)"

  echo
  info "== systemctl --user status ${UNIT_BASE}.service (as user: ${CF_USER}) =="
  user_systemctl "$CF_USER" status "${UNIT_BASE}.service" -l --no-pager || \
    warn "Could not read systemctl --user status for ${UNIT_BASE}.service"

  echo
  info "== Recent journal (last 30 lines) =="
  if user_systemctl "$CF_USER" list-units "${UNIT_BASE}.service" >/dev/null 2>&1; then
    sudo -u "$CF_USER" env XDG_RUNTIME_DIR="/run/user/$(user_uid "$CF_USER")" \
      journalctl --user -u "${UNIT_BASE}.service" -n 30 --no-pager 2>/dev/null || \
      warn "Could not read recent journal entries"
  else
    warn "${UNIT_BASE}.service unit not found; skipping journal output"
  fi
}

#------------------------------------------------------------------------------
# 2) Restart the cloudflared container
#------------------------------------------------------------------------------
action_restart() {
  echo
  info "Restarting ${UNIT_BASE}.service for user: ${CF_USER}"
  user_systemctl "$CF_USER" restart "${UNIT_BASE}.service" || die "Failed to restart ${UNIT_BASE}.service"

  sleep 2
  info "Restart complete. Current status:"
  user_systemctl "$CF_USER" status "${UNIT_BASE}.service" -l --no-pager || true
}

#------------------------------------------------------------------------------
# 3) Stop the cloudflared container
#------------------------------------------------------------------------------
action_stop() {
  echo
  info "Stopping ${UNIT_BASE}.service for user: ${CF_USER}"
  user_systemctl "$CF_USER" stop "${UNIT_BASE}.service" || die "Failed to stop ${UNIT_BASE}.service"

  sleep 1
  info "Stop complete. Current status:"
  user_systemctl "$CF_USER" status "${UNIT_BASE}.service" -l --no-pager || true
}

#------------------------------------------------------------------------------
# 4) Start the cloudflared container
#------------------------------------------------------------------------------
action_start() {
  echo
  info "Starting ${UNIT_BASE}.service for user: ${CF_USER}"
  user_systemctl "$CF_USER" start "${UNIT_BASE}.service" || die "Failed to start ${UNIT_BASE}.service"

  sleep 2
  info "Start complete. Current status:"
  user_systemctl "$CF_USER" status "${UNIT_BASE}.service" -l --no-pager || true
}

# Ensure the Quadlet .container unit has a "Network=pasta:-i,<iface>" line
# telling pasta which host interface to copy addresses/routes from.
# Older installs (created before this fix) have no Network= line at all,
# which leaves pasta defaulting to the host's main/default-route
# interface -- if TUNNEL_EDGE_BIND_ADDRESS is set to a *different*
# interface's address, cloudflared fails with:
#   bind: cannot assign requested address
# Called from action_upgrade so existing deployments get the fix without
# a full reinstall. Safe to call even when no bind address is set.
repair_pasta_network_line() {
  local bind_address="$1"
  [[ -f "$CONTAINER_FILE" ]] || { warn "Container unit not found, skipping network fix: ${CONTAINER_FILE}"; return 0; }

  local existing_network_line
  existing_network_line="$(grep -E '^Network=pasta:' "$CONTAINER_FILE" 2>/dev/null || true)"

  local iface=""
  if [[ -n "$bind_address" ]]; then
    iface="$(iface_for_ipv4_address "$bind_address")"
  fi

  if [[ -z "$iface" ]]; then
    if [[ -n "$existing_network_line" ]]; then
      info "Existing Network= line found (${existing_network_line}); leaving it as-is."
      return 0
    fi
    if [[ -n "$bind_address" ]]; then
      warn "Could not determine which interface currently owns ${bind_address}."
    fi
    read -r -p "Enter the network interface cloudflared should bind Edge connections to [skip]: " iface
    [[ -n "$iface" ]] || { warn "No interface given; not adding a Network= line."; return 0; }
    iface_exists "$iface" || die "Interface not found: ${iface}"
  fi

  local desired_network_line="Network=pasta:-i,${iface}"
  if [[ "$existing_network_line" == "$desired_network_line" ]]; then
    info "Network= line already correct (${desired_network_line})."
    return 0
  fi

  info "Setting ${desired_network_line} in ${CONTAINER_FILE}"
  if [[ -n "$existing_network_line" ]]; then
    sed -i -E "s#^Network=pasta:.*#${desired_network_line}#" "$CONTAINER_FILE"
  else
    sed -i "/^Exec=/a ${desired_network_line}" "$CONTAINER_FILE"
  fi
}

#------------------------------------------------------------------------------
# 5) Upgrade the cloudflared container
#------------------------------------------------------------------------------
action_upgrade() {
  [[ -f "$IMAGE_DROPIN" ]] || die "Image drop-in not found: ${IMAGE_DROPIN}"

  local current_tag=""
  # `|| true` guards against grep's non-zero "no match" exit under
  # `set -o pipefail` silently killing the script (see comment on
  # resolve_ipv4_addresses for the same failure mode).
  current_tag="$(grep -E '^Image=' "$IMAGE_DROPIN" 2>/dev/null | sed -E 's#^Image=docker\.io/cloudflare/cloudflared:##' || true)"

  echo
  info "Current image tag: ${current_tag:-unknown}"
  read -r -p "Enter the new cloudflared image tag (e.g., 2025.11.1): " NEW_TAG
  [[ -n "$NEW_TAG" ]] || die "Image tag cannot be empty"

  if [[ "$NEW_TAG" == "$current_tag" ]]; then
    read -r -p "New tag matches the current tag (${current_tag}). Continue anyway? [y/N]: " confirm_same
    [[ "${confirm_same,,}" == "y" ]] || { info "Upgrade cancelled."; return 0; }
  fi

  local new_image="docker.io/cloudflare/cloudflared:${NEW_TAG}"

  info "Pulling new image as user ${CF_USER}: ${new_image}"
  user_run "$CF_USER" "podman pull '${new_image}'" || die "Failed to pull image: ${new_image}"

  # Preserve the existing TUNNEL_EDGE_IP_VERSION / TUNNEL_EDGE_BIND_ADDRESS
  # settings rather than dropping them on upgrade.
  local current_edge_ip_version current_edge_bind_address
  current_edge_ip_version="$(grep -E '^Environment=TUNNEL_EDGE_IP_VERSION=' "$IMAGE_DROPIN" 2>/dev/null | sed -E 's#^Environment=TUNNEL_EDGE_IP_VERSION=##' || true)"
  current_edge_bind_address="$(grep -E '^Environment=TUNNEL_EDGE_BIND_ADDRESS=' "$IMAGE_DROPIN" 2>/dev/null | sed -E 's#^Environment=TUNNEL_EDGE_BIND_ADDRESS=##' || true)"
  current_edge_ip_version="${current_edge_ip_version:-4}"

  info "Updating image drop-in: ${IMAGE_DROPIN}"
  {
    echo "[Container]"
    echo "Image=${new_image}"
    echo "Pull=never"
    echo "Environment=TUNNEL_EDGE_IP_VERSION=${current_edge_ip_version}"
    if [[ -n "$current_edge_bind_address" ]]; then
      echo "Environment=TUNNEL_EDGE_BIND_ADDRESS=${current_edge_bind_address}"
    fi
  } >"${IMAGE_DROPIN}"
  chown "${CF_USER}:${CF_USER}" "${IMAGE_DROPIN}"
  chmod 0600 "${IMAGE_DROPIN}"

  repair_pasta_network_line "${current_edge_bind_address}"

  info "Reloading systemd --user daemon for user: ${CF_USER}"
  user_systemctl "$CF_USER" daemon-reload || die "Failed to reload user daemon"

  echo
  read -r -p "Restart ${UNIT_BASE}.service now to apply the new image? [Y/n]: " do_restart
  do_restart="${do_restart:-y}"
  if [[ "${do_restart,,}" == "y" ]]; then
    user_systemctl "$CF_USER" restart "${UNIT_BASE}.service" || die "Failed to restart ${UNIT_BASE}.service after upgrade"
    sleep 2
    info "Upgrade complete. Current status:"
    user_systemctl "$CF_USER" status "${UNIT_BASE}.service" -l --no-pager || true
  else
    warn "Image updated but service not restarted. The old container keeps running the previous image until restarted."
  fi
}

#------------------------------------------------------------------------------
# 6) Change the tunnel token
#------------------------------------------------------------------------------
action_change_token() {
  [[ -f "$TOKEN_ENV_FILE" ]] || die "Token env file not found: ${TOKEN_ENV_FILE}"

  echo
  warn "The new token will be visible on screen while typing."
  read -r -p "Enter the new tunnel token: " NEW_TOKEN
  [[ -n "$NEW_TOKEN" ]] || die "Token cannot be empty"

  info "Updating token file: ${TOKEN_ENV_FILE}"
  cat >"${TOKEN_ENV_FILE}" <<EOF
TUNNEL_TOKEN=${NEW_TOKEN}
EOF
  chown "${CF_USER}:${CF_USER}" "${TOKEN_ENV_FILE}"
  chmod 0600 "${TOKEN_ENV_FILE}"

  info "Reloading systemd --user daemon for user: ${CF_USER}"
  user_systemctl "$CF_USER" daemon-reload || die "Failed to reload user daemon"

  echo
  read -r -p "Restart ${UNIT_BASE}.service now to apply the new token? [Y/n]: " do_restart
  do_restart="${do_restart:-y}"
  if [[ "${do_restart,,}" == "y" ]]; then
    user_systemctl "$CF_USER" restart "${UNIT_BASE}.service" || die "Failed to restart ${UNIT_BASE}.service after token change"
    sleep 2
    info "Token updated. Current status:"
    user_systemctl "$CF_USER" status "${UNIT_BASE}.service" -l --no-pager || true
  else
    warn "Token updated but service not restarted. The old token stays active until restarted."
  fi
}

#------------------------------------------------------------------------------
# 7) Reload the systemd --user daemon
#------------------------------------------------------------------------------
action_daemon_reload() {
  echo
  info "Running systemctl --user daemon-reload for user: ${CF_USER}"
  user_systemctl "$CF_USER" daemon-reload || die "Failed to reload user daemon"
  info "Daemon reload complete."
}

action_refresh_edge_routing() {
  local edge_iface
  edge_iface="$(edge_iface_from_container_file)" || return 0
  echo
  info "Refreshing Cloudflare Tunnel edge static routes on interface: ${edge_iface}"
  configure_edge_routing "$edge_iface"
}

print_menu() {
  echo
  echo "=========================================="
  echo " cloudflared-container management (instance: ${INSTANCE}, user: ${CF_USER})"
  echo "=========================================="
  echo "  1) Show status"
  echo "  2) Restart container"
  echo "  3) Stop container"
  echo "  4) Start container"
  echo "  5) Upgrade container (change image tag, repair pasta network line)"
  echo "  6) Change tunnel token"
  echo "  7) Reload systemd --user daemon"
  echo "  8) Switch base username / prod-dev instance"
  echo "  9) Refresh Cloudflare Tunnel edge static routes"
  echo "  q) Quit"
  echo
}

main() {
  require_root
  resolve_instance

  # Allow non-interactive one-shot invocation, still prompting first for
  # base username / instance:
  #   cloudflared-container status|restart|stop|start|upgrade|change-token|daemon-reload
  if [[ "${1:-}" != "" ]]; then
    case "${1}" in
      status)        action_status ;;
      restart)       action_restart ;;
      stop)          action_stop ;;
      start)         action_start ;;
      upgrade)       action_upgrade ;;
      change-token)  action_change_token ;;
      daemon-reload) action_daemon_reload ;;
      refresh-edge-routing) action_refresh_edge_routing ;;
      *) die "Unknown action: ${1}. Valid actions: status, restart, stop, start, upgrade, change-token, daemon-reload, refresh-edge-routing" ;;
    esac
    exit 0
  fi

  while true; do
    print_menu
    read -r -p "Select an option: " choice
    case "$choice" in
      1) action_status ;;
      2) action_restart ;;
      3) action_stop ;;
      4) action_start ;;
      5) action_upgrade ;;
      6) action_change_token ;;
      7) action_daemon_reload ;;
      8) resolve_instance ;;
      9) action_refresh_edge_routing ;;
      q|Q) info "Exiting."; exit 0 ;;
      *) warn "Invalid selection: ${choice}" ;;
    esac
  done
}

main "$@"
MANAGE_SCRIPT_EOF

  chmod 0755 "${install_path}"
  chown root:root "${install_path}"

  info "Management command installed: ${install_path}"
  info "  Run interactively: sudo cloudflared-container"
  info "  Or non-interactively (after prompting for base username/instance): sudo cloudflared-container status|restart|upgrade"
}

# Create the Quadlet unit + drop-ins for one cloudflared instance.
#   instance: "prod" or "dev"
#     - prod uses unit basename "cloudflared" (unit: cloudflared.service)
#     - dev uses unit basename "cloudflared-dev" (unit: cloudflared-dev.service)
#       and all drop-in filenames are suffixed "-dev"
#   edge_bind_address: IPv4 address written to TUNNEL_EDGE_BIND_ADDRESS in
#     the image drop-in, alongside a hardcoded TUNNEL_EDGE_IP_VERSION=4.
#     Same value used for both prod and dev (derived once from the
#     interface the user selects in main()).
#   edge_iface: the same interface edge_bind_address was derived from.
#     Passed to pasta as "-i <iface>" (Network=pasta:-i,<iface> in the
#     unit) so pasta copies that interface's address/routes into the
#     container namespace -- otherwise pasta only copies the host's
#     main/default-route interface, and binding to a non-default
#     interface's address from inside the container fails with
#     "bind: cannot assign requested address".
create_quadlet_rootless() {
  local instance="$1" u="$2" tag="$3" token="$4" edge_bind_address="$5" edge_iface="$6"
  local homedir quadlet_dir unit_base container_name container_file dropin_dir
  local image_dropin icmp_dropin token_dropin env_file suffix

  homedir="$(getent passwd "$u" | awk -F: '{print $6}')"
  [[ -n "$homedir" && -d "$homedir" ]] || die "Could not determine home directory for user: $u"

  if [[ "$instance" == "prod" ]]; then
    unit_base="cloudflared"
    container_name="cloudflared"
    suffix=""
  else
    unit_base="cloudflared-dev"
    container_name="cloudflared-dev"
    suffix="-dev"
  fi

  quadlet_dir="${homedir}/.config/containers/systemd"
  container_file="${quadlet_dir}/${unit_base}.container"
  dropin_dir="${quadlet_dir}/${unit_base}.container.d"
  image_dropin="${dropin_dir}/40-image${suffix}.conf"
  icmp_dropin="${dropin_dir}/50-icmp${suffix}.conf"
  token_dropin="${dropin_dir}/50-token${suffix}.conf"
  env_file="${dropin_dir}/cloudflared${suffix}.env"

  info "Creating Quadlet files for instance '${instance}' (unit: ${unit_base}.service) under user $u"

  install -d -m 0700 -o "$u" -g "$u" "$quadlet_dir"
  install -d -m 0700 -o "$u" -g "$u" "$dropin_dir"

  cat >"$container_file" <<EOF
[Unit]
Description=CloudflareD Tunnel Agent (cloudflared) Container -- ${instance}
Wants=network-online.target
After=network-online.target

[Container]
ContainerName=${container_name}
Exec=tunnel --no-autoupdate run
Network=pasta:-i,${edge_iface}

[Service]
Restart=always
TimeoutStartSec=900

[Install]
WantedBy=default.target
EOF
  chown "$u:$u" "$container_file"
  chmod 0600 "$container_file"

  cat >"$image_dropin" <<EOF
[Container]
Image=docker.io/cloudflare/cloudflared:${tag}
Pull=never
Environment=TUNNEL_EDGE_IP_VERSION=4
Environment=TUNNEL_EDGE_BIND_ADDRESS=${edge_bind_address}
EOF
  chown "$u:$u" "$image_dropin"
  chmod 0600 "$image_dropin"

  cat >"$icmp_dropin" <<EOF
[Container]
Sysctl="net.ipv4.ping_group_range=65532 65532"
EOF
  chown "$u:$u" "$icmp_dropin"
  chmod 0600 "$icmp_dropin"

  # Pass the tunnel token via environment rather than as a CLI argument.
  # A --token CLI arg would be visible to any local user via `ps` or
  # /proc/<pid>/cmdline (both world-readable), regardless of file
  # permissions on this drop-in. Env vars land in /proc/<pid>/environ,
  # which is readable only by the owning user and root.
  cat >"$env_file" <<EOF
TUNNEL_TOKEN=${token}
EOF
  chown "$u:$u" "$env_file"
  chmod 0600 "$env_file"

  cat >"$token_dropin" <<EOF
[Container]
EnvironmentFile=${env_file}

[Service]
LimitNOFILE=250000
EOF
  chown "$u:$u" "$token_dropin"
  chmod 0600 "$token_dropin"

  info "Reloading generator and starting service as user $u"
  user_systemctl "$u" daemon-reload
  user_systemctl "$u" reset-failed "${unit_base}.service" || true
  user_systemctl "$u" start "${unit_base}.service"
  user_systemctl "$u" status "${unit_base}.service" -l --no-pager || true
}

# Append profile.d alias definitions for one instance to the shared
# aliases file. unit_base/alias_suffix let prod keep unsuffixed alias
# names (cloudflared-status) while dev gets "-dev" suffixed names
# (cloudflared-status-dev), avoiding collisions when both are installed.
write_cloudflared_aliases() {
  local instance_user="$1" unit_base="$2" alias_suffix="$3"

  cat >>/etc/profile.d/cloudflared-aliases.sh <<EOF
alias cloudflared-status${alias_suffix}='sudo -u ${instance_user} XDG_RUNTIME_DIR=/run/user/\$(id -u ${instance_user}) systemctl --user status ${unit_base}.service'
alias cloudflared-stop${alias_suffix}='sudo -u ${instance_user} XDG_RUNTIME_DIR=/run/user/\$(id -u ${instance_user}) systemctl --user stop ${unit_base}.service'
alias cloudflared-start${alias_suffix}='sudo -u ${instance_user} XDG_RUNTIME_DIR=/run/user/\$(id -u ${instance_user}) systemctl --user start ${unit_base}.service'
alias cloudflared-restart${alias_suffix}='sudo -u ${instance_user} XDG_RUNTIME_DIR=/run/user/\$(id -u ${instance_user}) systemctl --user restart ${unit_base}.service'
EOF
}

main() {
  require_root

  iface_exists eth0 || die "Interface eth0 not found. This script expects eth0 as the primary NIC."

  install_packages

  #-----------------------------------------------------------------------
  # Base username -- always suffixed "-prod" / "-dev" per instance
  #-----------------------------------------------------------------------
  echo
  read -r -p "Enter base username for cloudflared (rootless) [cloudflared]: " BASE_USER
  BASE_USER="${BASE_USER:-cloudflared}"

  CF_USER="${BASE_USER}-prod"

  #-----------------------------------------------------------------------
  # Cloudflare Edge bind address -- same value used for both prod and dev.
  # TUNNEL_EDGE_IP_VERSION is always "4"; no prompt needed for it.
  #-----------------------------------------------------------------------
  echo
  local edge_iface=""
  while true; do
    read -r -p "Enter the network interface to bind outgoing Cloudflare Edge connections to [eth0]: " edge_iface
    edge_iface="${edge_iface:-eth0}"
    if iface_exists "${edge_iface}"; then
      break
    fi
    warn "Interface not found: ${edge_iface}"
  done

  EDGE_BIND_ADDRESS="$(iface_ipv4_address "${edge_iface}")"
  [[ -n "${EDGE_BIND_ADDRESS}" ]] || die "Could not determine an IPv4 address for interface: ${edge_iface}"
  info "Using TUNNEL_EDGE_BIND_ADDRESS=${EDGE_BIND_ADDRESS} (from interface ${edge_iface}), TUNNEL_EDGE_IP_VERSION=4"

  configure_edge_routing "${edge_iface}"

  #-----------------------------------------------------------------------
  # "prod" instance (always installed)
  #-----------------------------------------------------------------------
  echo
  info "Configuring the 'prod' cloudflared container (user: ${CF_USER})"
  ensure_user "${CF_USER}"

  read -r -p "Enter prod cloudflared image tag (e.g., 2025.11.1): " CF_TAG
  [[ -n "${CF_TAG}" ]] || die "Image tag cannot be empty"

  echo
  read -r -s -p "Enter prod Cloudflare tunnel token (dashboard-generated): " CF_TOKEN
  echo
  [[ -n "${CF_TOKEN}" ]] || die "Tunnel token cannot be empty"

  enable_persistent_journaling
  write_sysctl_cloudflared

  enable_linger_for_user "${CF_USER}"
  pull_cloudflared_image_rootless "${CF_USER}" "${CF_TAG}"
  create_quadlet_rootless "prod" "${CF_USER}" "${CF_TAG}" "${CF_TOKEN}" "${EDGE_BIND_ADDRESS}" "${edge_iface}"

  #-----------------------------------------------------------------------
  # "dev" instance (optional) -- always runs as "${BASE_USER}-dev"
  #-----------------------------------------------------------------------
  echo
  read -r -p "Install a second (dev) cloudflared container? [y/N]: " INSTALL_DEV
  INSTALL_DEV="${INSTALL_DEV:-n}"

  DEV_USER="${BASE_USER}-dev"
  if [[ "${INSTALL_DEV,,}" == "y" ]]; then
    info "Configuring the 'dev' cloudflared container (user: ${DEV_USER})"
    ensure_user "${DEV_USER}"

    read -r -p "Enter dev cloudflared image tag (e.g., 2025.11.1): " DEV_TAG
    [[ -n "${DEV_TAG}" ]] || die "Image tag cannot be empty"

    echo
    read -r -s -p "Enter dev Cloudflare tunnel token (dashboard-generated): " DEV_TOKEN
    echo
    [[ -n "${DEV_TOKEN}" ]] || die "Tunnel token cannot be empty"

    enable_linger_for_user "${DEV_USER}"
    pull_cloudflared_image_rootless "${DEV_USER}" "${DEV_TAG}"
    create_quadlet_rootless "dev" "${DEV_USER}" "${DEV_TAG}" "${DEV_TOKEN}" "${EDGE_BIND_ADDRESS}" "${edge_iface}"
  else
    info "Skipping dev container installation."
  fi

  #-----------------------------------------------------------------------
  # Single merged management command (covers both prod and dev)
  #-----------------------------------------------------------------------
  install_management_command

  #-----------------------------------------------------------------------
  # Shared profile.d aliases
  #-----------------------------------------------------------------------
  info "Installing cloudflared aliases for user ${CF_USER}"
  : >/etc/profile.d/cloudflared-aliases.sh
  echo 'export PATH="/usr/local/sbin:$PATH"' >>/etc/profile.d/cloudflared-aliases.sh
  write_cloudflared_aliases "${CF_USER}" "cloudflared" ""

  if [[ "${INSTALL_DEV,,}" == "y" ]]; then
    info "Installing dev cloudflared aliases for user ${DEV_USER}"
    write_cloudflared_aliases "${DEV_USER}" "cloudflared-dev" "-dev"
  fi

  chmod 0644 /etc/profile.d/cloudflared-aliases.sh

  info "Done. Verify after reboot:"
  echo "  sudo -u ${CF_USER} env XDG_RUNTIME_DIR=/run/user/\$(id -u ${CF_USER}) systemctl --user status cloudflared.service -l --no-pager"
  echo "  journalctl --user -u cloudflared.service -b --no-pager | tail -n 200"
  echo "  Manage: sudo cloudflared-container (prompts for base username '${BASE_USER}' and prod/dev)"

  if [[ "${INSTALL_DEV,,}" == "y" ]]; then
    echo "  sudo -u ${DEV_USER} env XDG_RUNTIME_DIR=/run/user/\$(id -u ${DEV_USER}) systemctl --user status cloudflared-dev.service -l --no-pager"
    echo "  journalctl --user -u cloudflared-dev.service -b --no-pager | tail -n 200"
  fi
}

main "$@"
